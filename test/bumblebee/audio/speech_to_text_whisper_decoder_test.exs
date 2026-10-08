# Exercise the decoder without loading a model. The renamed module exposes
# private helpers only in this test and leaves the production API unchanged.
# A deterministic tokenizer isolates stitching from model accuracy.

defmodule Bumblebee.Audio.WhisperDecoderTestTokenizer do
  defstruct []

  @words %{
    1 => "The",
    2 => "final",
    3 => "signal",
    4 => "flashed",
    5 => "from",
    6 => "the",
    7 => "tall",
    8 => "tower.",
    9 => "Purple",
    10 => "Elephant",
    11 => "crossed",
    12 => "quiet",
    13 => "river.",
    14 => "A",
    15 => "silver",
    16 => "comet",
    17 => "lit",
    18 => "northern",
    19 => "sky."
  }
  def special_tokens(_), do: %{}
  def additional_special_tokens(_), do: []
  def token_to_id(_, "<|notimestamps|>"), do: 1000
  def id_to_token(_, id), do: Map.fetch!(@words, id)
  def decode(_, ids), do: Enum.map_join(ids, " ", &Map.fetch!(@words, &1))
end

source =
  Path.expand("../../../lib/bumblebee/audio/speech_to_text_whisper.ex", __DIR__) |> File.read!()

ast = Code.string_to_quoted!(source)

ast =
  Macro.postwalk(ast, fn
    {:defmodule, meta, [{:__aliases__, ameta, [:Bumblebee, :Audio, :SpeechToTextWhisper]}, body]} ->
      {:defmodule, meta,
       [{:__aliases__, ameta, [:Bumblebee, :Audio, :WhisperDecoderUnderTest]}, body]}

    {:defp, meta, [{name, _, _} = call, body]}
    when name in [:decode_chunk_outputs_init, :process_output, :decode_chunk_outputs_finish] ->
      {:def, meta, [call, body]}

    node ->
      node
  end)

Code.compile_quoted(ast)

defmodule Bumblebee.Audio.SpeechToTextWhisperDecoderTest do
  use ExUnit.Case, async: true

  alias Bumblebee.Audio.WhisperDecoderUnderTest, as: Decoder

  @options %{
    timestamps?: true,
    sampling_rate: 16_000,
    chunk_num_seconds: 30,
    context_num_seconds: 5
  }
  @tokenizer %Bumblebee.Audio.WhisperDecoderTestTokenizer{}
  @old [1, 2, 3, 4, 5, 6, 7, 8]
  @new [1, 9, 10, 11, 6, 12, 13]
  @next [14, 15, 16, 17, 6, 18, 19]

  defp timestamp(seconds), do: 1001 + round(seconds / 0.02)

  defp pending(end_time) do
    Decoder.decode_chunk_outputs_init(
      %{encoder_max_positions: 1500},
      %{num_seconds: 30},
      @tokenizer
    )
    |> Map.merge(%{
      time_offset: 85.0,
      right_context_end_time: end_time,
      previous_sequences: [@old],
      chunk: %{start_timestamp_seconds: 70.28, end_timestamp_seconds: nil, text: nil}
    })
  end

  test "disjoint predictions preserve both phrases instead of joining coincidental words" do
    state = pending(72.44)

    sequence =
      [timestamp(0)] ++
        @new ++ [timestamp(13.68), timestamp(13.68)] ++ @next ++ [timestamp(16.44)]

    state =
      Decoder.process_output(
        state,
        sequence,
        @tokenizer,
        @options
      )

    {chunks, _} =
      Decoder.decode_chunk_outputs_finish(
        state,
        @tokenizer,
        @options
      )

    assert Enum.map(chunks, & &1.text) == [
             "The final signal flashed from the tall tower.",
             "The Purple Elephant crossed the quiet river.",
             "A silver comet lit the northern sky."
           ]

    assert Enum.map(chunks, &{&1.start_timestamp_seconds, &1.end_timestamp_seconds}) == [
             {70.28, 72.44},
             {80.0, 93.68},
             {93.68, 96.44}
           ]
  end

  test "predictions that overlap in time still deduplicate matching tokens" do
    state = pending(86.0)
    sequence = [timestamp(0)] ++ @old ++ [timestamp(6), timestamp(6)] ++ @next ++ [timestamp(8)]

    state =
      Decoder.process_output(
        state,
        sequence,
        @tokenizer,
        @options
      )

    {chunks, _} =
      Decoder.decode_chunk_outputs_finish(
        state,
        @tokenizer,
        @options
      )

    assert Enum.map(chunks, & &1.text) == [
             "The final signal flashed from the tall tower.",
             "A silver comet lit the northern sky."
           ]

    assert Enum.map(chunks, &{&1.start_timestamp_seconds, &1.end_timestamp_seconds}) == [
             {70.28, 86.0},
             {86.0, 88.0}
           ]
  end

  test "unknown prior endpoint retains existing overlap behavior" do
    state = pending(nil)
    sequence = [timestamp(0)] ++ @old ++ [timestamp(6), timestamp(6)] ++ @next ++ [timestamp(8)]

    state =
      Decoder.process_output(
        state,
        sequence,
        @tokenizer,
        @options
      )

    {chunks, _} =
      Decoder.decode_chunk_outputs_finish(
        state,
        @tokenizer,
        @options
      )

    assert Enum.map(chunks, & &1.text) == [
             "The final signal flashed from the tall tower.",
             "A silver comet lit the northern sky."
           ]
  end
end

defmodule Ockam.Stream.Index.KafkaOffset do
  @moduledoc """
    Kafka storage backend for ockam stream index service
    Using kafka offset storage
  """
  @behaviour Ockam.Stream.Index.Storage

  alias Ockam.Kafka

  require Logger

  defstruct [:client, :options]

  @default_client_id :ockam_stream_index

  @impl true
  def init(options) do
    with {:ok, client} <- Kafka.create_client(options, @default_client_id) do
      {:ok, %__MODULE__{client: client, options: options}}
    end
  end

  @impl true
  def get_index(client_id, stream_name, partition, state) do
    %__MODULE__{client: client, options: options} = state
    topic = Kafka.topic(stream_name, options)
    partition = Kafka.partition(stream_name, partition, options)
    consumer_id = Kafka.consumer_id(client_id, options)

    result =
      case :brod_utils.fetch_committed_offsets(client, consumer_id, [{topic, [partition]}]) do
        {:ok,
         [
           %{
             partition_responses: [
               %{error_code: :no_error, metadata: _, offset: offset, partition: ^partition}
             ],
             topic: ^topic
           }
         ]} ->
          offset =
            case offset do
              -1 -> :undefined
              non_neg when non_neg >= 0 -> non_neg
            end

          {:ok, offset}

        {:error, err} ->
          {:error, err}
      end

    {result, state}
  end

  @impl true
  def save_index(client_id, stream_name, partition, index, state) do
    %__MODULE__{options: options} = state
    consumer_id = Kafka.consumer_id(client_id, options)
    topic = Kafka.topic(stream_name, options)
    partition = Kafka.partition(stream_name, partition, options)

    {commit_offset(consumer_id, topic, partition, index, state), state}
  end

  def commit_offset(consumer_id, topic, partition, index, state) do
    %__MODULE__{client: client, options: options} = state

    req_body = [
      group_id: consumer_id,
      generation_id: -1,
      member_id: "",
      retention_time: -1,
      topics: [
        [
          topic: topic,
          partitions: [
            [
              partition: partition,
              offset: index,
              metadata: ""
            ]
          ]
        ]
      ]
    ]

    with {:ok, conn} <- :brod_client.get_leader_connection(client, topic, partition) do
      req = :brod_kafka_request.offset_commit(conn, req_body)

      case :brod_utils.request_sync(conn, req, request_timeout(options)) do
        {:ok,
         %{
           responses: [
             %{
               partition_responses: [%{error_code: :no_error, partition: ^partition}],
               topic: ^topic
             }
           ]
         }} ->
          :ok

        {:ok, %{responses: [%{partition_responses: [%{error_code: error}]}]}} ->
          {:error, {:commit_error, error}}
      end
    end
  end

  def request_timeout(options) do
    options |> Kafka.request_configs() |> Map.fetch!(:timeout)
  end
end

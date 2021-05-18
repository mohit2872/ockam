defmodule Ockam.Kafka do
  @moduledoc """
  Helper functions for ockam kafka backends
  """

  require Logger

  def client_id(options, default) do
    Keyword.get(options, :client_id, default)
  end

  def endpoints(options) do
    Keyword.get(options, :endpoints, Application.get_env(:ockam_kafka, :endpoints))
  end

  def request_configs(_options) do
    %{timeout: 30_000}
  end

  def topic(stream_name, options) do
    prefix = Keyword.get(options, :topic_prefix, "")
    prefix <> stream_name
  end

  def partition(_stream_name, partition, _options) do
    partition
  end

  def consumer_id(client_id, _options) do
    client_id
  end

  def client_config(options) do
    producer_config = [{:auto_start_producers, true}, {:default_producer_config, []}]
    Keyword.get(options, :client_config, []) ++ producer_config
  end

  def create_client(options, default_client_id) do
    endpoints = endpoints(options)
    client_id = client_id(options, default_client_id)
    client_config = client_config(options)

    ## TODO: use supervised client
    case :brod.start_link_client(endpoints, client_id, client_config) do
      {:ok, client} -> {:ok, client}
      {:error, {:already_started, client}} -> {:ok, client}
      {:error, err} -> {:error, err}
    end
  end

  def create_topic(topic, partitions, options) do
    endpoints = endpoints(options)
    topic_configs = topic_configs(topic, partitions, options)
    request_configs = request_configs(options)
    client_config = client_config(options)

    case :brod.create_topics(endpoints, topic_configs, request_configs, client_config) do
      :ok -> :ok
      ## TODO: optional failure
      {:error, :topic_already_exists} -> :ok
      {:error, err} -> {:error, err}
    end
  end

  ## TODO: pass more options here
  def topic_configs(topic, partitions, options) do
    [
      %{
        replication_factor: Keyword.get(options, :replication_factor, 1),
        replica_assignment: [],
        config_entries: [],
        num_partitions: partitions,
        topic: topic
      }
    ]
  end
end

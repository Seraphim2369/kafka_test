from pyspark.sql import SparkSession
from pyspark.sql.functions import *
from pyspark.sql.types import *

def create_spark_session():
    return SparkSession.builder \
        .appName("KafkaSparkProcessor") \
        .config("spark.jars.packages", "org.apache.spark:spark-sql-kafka-0-10_2.12:3.4.1") \
        .getOrCreate()

def process_kafka_stream(spark, kafka_servers, input_topic, output_topic):
    # Read from Kafka
    df = spark \
        .readStream \
        .format("kafka") \
        .option("kafka.bootstrap.servers", kafka_servers) \
        .option("subscribe", input_topic) \
        .load()

    # Process the data
    processed_df = df.select(
        col("key").cast("string"),
        col("value").cast("string"),
        col("timestamp")
    ).withColumn("processed_at", current_timestamp())

    # Write back to Kafka
    query = processed_df.select(
        col("key"),
        to_json(struct("*")).alias("value")
    ).writeStream \
        .format("kafka") \
        .option("kafka.bootstrap.servers", kafka_servers) \
        .option("topic", output_topic) \
        .option("checkpointLocation", "/tmp/checkpoint") \
        .start()

    return query

if __name__ == "__main__":
    spark = create_spark_session()

    kafka_servers = "kafka:9092"
    input_topic = "spark-input"
    output_topic = "spark-output"

    query = process_kafka_stream(spark, kafka_servers, input_topic, output_topic)
    query.awaitTermination()
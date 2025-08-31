from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator

default_args = {
    'owner': 'data-team',
    'depends_on_past': False,
    'start_date': datetime(2024, 1, 1),
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

dag = DAG(
    'kafka_spark_pipeline',
    default_args=default_args,
    description='Process data from Kafka using Spark',
    schedule_interval=timedelta(hours=1),
    catchup=False,
)

def check_kafka_health():
    import subprocess
    # Updated to use docker compose without hyphen
    result = subprocess.run(['docker', 'compose', 'exec', '-T', 'kafka', 'kafka-topics.sh',
                             '--list', '--bootstrap-server', 'localhost:9092'],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise Exception("Kafka is not healthy")
    print("Kafka topics:", result.stdout)

check_kafka_task = PythonOperator(
    task_id='check_kafka_health',
    python_callable=check_kafka_health,
    dag=dag,
)

submit_spark_job = BashOperator(
    task_id='submit_spark_job',
    bash_command='''
    docker compose exec -T spark-master spark-submit \
        --master spark://spark-master:7077 \
        /opt/spark-apps/jobs/kafka_processor.py
    ''',
    dag=dag,
)

check_kafka_task >> submit_spark_job
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir scikit-learn==1.3.2 pandas==2.2.0 pyarrow==15.0.0 google-cloud-storage==2.16.0 joblib==1.3.2
COPY ml/pipelines/log_embedding_anomaly/train.py /app/train.py
ENTRYPOINT ["python", "/app/train.py"]

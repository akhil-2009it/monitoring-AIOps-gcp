FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

WORKDIR /app
COPY api/scoring/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY api/__init__.py            /app/api/__init__.py
COPY api/scoring                /app/api/scoring

RUN useradd -m -u 1000 api && chown -R api /app
USER api

ENV PYTHONPATH=/app PORT=8080
EXPOSE 8080
CMD ["sh", "-c", "uvicorn api.scoring.main:app --host 0.0.0.0 --port ${PORT}"]

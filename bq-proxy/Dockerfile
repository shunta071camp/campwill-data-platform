FROM python:3.12-slim

WORKDIR /app

# 依存先インストール (キャッシュ効率優先)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# アプリ本体
COPY app.py .

ENV PORT=8080
EXPOSE 8080

# Cloud Run の冷起動を抑えつつ、Claude API の長時間応答にも耐える設定
CMD exec gunicorn --bind :$PORT --workers 1 --threads 8 --timeout 120 --keep-alive 75 app:app

# syntax=docker/dockerfile:1

FROM python:3.12-slim

# PYTHONDONTWRITEBYTECODE: no .pyc clutter in the image layer
# PYTHONUNBUFFERED: logs reach stdout immediately instead of sitting in a
#   buffer, which matters because Cloud Logging reads stdout
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

WORKDIR /app

# Copy requirements FIRST, install, THEN copy source. Docker caches layers, so
# editing main.py does not re-run pip install. This one ordering decision is
# the difference between a 5-second and a 90-second CI build.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py ./

# Run as a non-root, non-privileged user. Kubernetes will also enforce this
# via securityContext.runAsNonRoot, and the Pod will refuse to start if the
# image's default user is root.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser
USER 10001

EXPOSE 8080

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]

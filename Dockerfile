# Use an official Python runtime as a parent image
# gamdl requires Python 3.9+
# Using non-slim version for a more complete ffmpeg environment
FROM python:3.11-bookworm

# Set environment variables to prevent Python from writing .pyc files to disc and to buffer output
ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1

# Set the working directory in the container
WORKDIR /app

# Install system dependencies
# - ffmpeg is required by gamdl
# - git is needed to clone Bento4
# - curl is a general utility
RUN apt-get update && \
    apt-get install -y --no-install-recommends ffmpeg git curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install Bento4 (for mp4decrypt) by compiling from source
ENV BENTO4_VERSION v1.6.0-641 # Using a recent stable tag for Bento4
RUN apt-get update && \
    apt-get install -y --no-install-recommends cmake build-essential python3-dev && \
    git clone --depth 1 --branch ${BENTO4_VERSION} https://github.com/axiomatic-systems/Bento4.git /tmp/Bento4 && \
    cd /tmp/Bento4 && \
    cmake -B build -S . -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build --config Release --parallel $(nproc) && \
    cp build/mp4decrypt /usr/local/bin/ && \
    cp build/mp4info /usr/local/bin/ && \
    chmod +x /usr/local/bin/mp4decrypt /usr/local/bin/mp4info && \
    cd / && \
    rm -rf /tmp/Bento4 && \
    apt-get purge -y --auto-remove cmake build-essential python3-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy the requirements file into the container
COPY requirements.txt .

# Install Python dependencies specified in requirements.txt
# --no-cache-dir reduces image size
RUN pip install --no-cache-dir -r requirements.txt

# Install gamdl itself
# Using --no-cache-dir to keep the image lean
RUN pip install --no-cache-dir gamdl

# Copy the rest of the application code (app.py, templates folder, etc.) into the container
COPY . .

# The port your app runs on (Flask default is 5000)
# This is for documentation; the actual port mapping is done in docker-compose.yml
EXPOSE 5000

# The command to run your application using Gunicorn as a production WSGI server.
# For Flask-SocketIO with async_mode='threading', use the 'gthread' worker.
# -w specifies the number of worker processes.
# --threads specifies the number of threads per worker.
# You might need to adjust these values based on your server's resources and expected load.
# Example: 2 workers, 4 threads per worker.
# The app:app refers to the 'app' Flask application object in the 'app.py' file.
CMD ["gunicorn", "-w", "1", "--threads", "4", "-b", "0.0.0.0:5000", "app:app"]

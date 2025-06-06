# Use an official Python runtime as a parent image
# gamdl requires Python 3.9+
FROM python:3.11-slim-bookworm

# Set environment variables to prevent Python from writing .pyc files to disc and to buffer output
ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1

# Set the working directory in the container
WORKDIR /app

# Install system dependencies
# - ffmpeg is required by gamdl
# - git can be useful for some pip installs
# - unzip is needed to extract Bento4
# - curl or wget is needed to download Bento4 (curl is often preferred)
RUN apt-get update && \
    apt-get install -y ffmpeg git unzip curl && \
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

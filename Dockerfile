# Use a Debian base image suitable for Homebrew on Linux
FROM debian:bookworm-slim

# Set environment variables for non-interactive setup and Python behavior
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

# Path for Homebrew - This sets the PATH to include Homebrew's directories
ENV PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:${PATH}"

# Install prerequisites for Homebrew, Bento4 compilation, and other utilities.
# Note: Homebrew will install its own versions of many tools (like git, curl, python, ffmpeg).
# System dependencies for Pillow and PyYAML are included here as a fallback,
# though Homebrew should manage these for its own packages.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        procps \
        curl \
        file \
        git \
        sudo \
        cmake \
        python3-dev \
        xz-utils \
        libjpeg62-turbo-dev \
        zlib1g-dev \
        libtiff5-dev \
        liblcms2-dev \
        libwebp-dev \
        libfreetype6-dev \
        libharfbuzz-dev \
        libfribidi-dev \
        libxcb1-dev \
        libyaml-dev \
    && apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create a non-root user for Homebrew installation and application execution
RUN groupadd --gid 1000 linuxbrew && \
    useradd --uid 1000 --gid 1000 --shell /bin/bash --create-home linuxbrew && \
    echo "linuxbrew ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Switch to the linuxbrew user for Homebrew installation
USER linuxbrew
WORKDIR /home/linuxbrew

# Install Homebrew. The script installs it into /home/linuxbrew/.linuxbrew
RUN /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install gamdl using Homebrew. This will also install ffmpeg, python@3.13, etc.
RUN brew install gamdl

# Set ENV vars for Homebrew's Python tools (based on gamdl's current dependency on python@3.13)
# These paths are typical for Homebrew installations.
ENV BREW_PYTHON_PREFIX="/home/linuxbrew/.linuxbrew/opt/python@3.13"
ENV BREW_PIP_PATH="${BREW_PYTHON_PREFIX}/bin/pip3"
ENV BREW_PYTHON_PATH="${BREW_PYTHON_PREFIX}/bin/python3"
ENV BREW_GUNICORN_PATH="${BREW_PYTHON_PREFIX}/bin/gunicorn"

# Switch back to root for operations requiring root privileges
USER root
# Set WORKDIR for the application code
WORKDIR /app

# Install Bento4 (for mp4decrypt) by compiling from source
# Build dependencies (cmake, build-essential, python3-dev) were installed earlier.
ENV BENTO4_VERSION v1.6.0-641
RUN git clone --depth 1 --branch ${BENTO4_VERSION} https://github.com/axiomatic-systems/Bento4.git /tmp/Bento4 && \
    cd /tmp/Bento4 && \
    cmake -B build -S . -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build --config Release --parallel $(nproc) && \
    cp build/mp4decrypt /usr/local/bin/ && \
    cp build/mp4info /usr/local/bin/ && \
    chmod +x /usr/local/bin/mp4decrypt /usr/local/bin/mp4info && \
    cd / && \
    rm -rf /tmp/Bento4 && \
    # Purge build-time dependencies for Bento4.
    # Be cautious if Homebrew might have relied on system versions of these, though unlikely.
    apt-get purge -y --auto-remove cmake build-essential python3-dev && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy the requirements file into the container
COPY requirements.txt .
RUN chown linuxbrew:linuxbrew requirements.txt

# Install Python dependencies for the web application using Homebrew's Python/pip.
# Must run as linuxbrew user to install into Homebrew's Python environment.
USER linuxbrew
RUN ${BREW_PIP_PATH} install --no-cache-dir -r requirements.txt
USER root

# Copy the rest of the application code into the container
COPY . .
# Ensure the app directory and its contents are owned by the linuxbrew user
RUN chown -R linuxbrew:linuxbrew /app

# The port your app runs on
EXPOSE 5000

# Switch to linuxbrew user to run the application
USER linuxbrew
WORKDIR /app # Ensure WORKDIR is /app for the CMD instruction

# The command to run your application using Gunicorn from Homebrew's Python environment
# Using sh -c to allow ENV var expansion for BREW_GUNICORN_PATH
CMD ["sh", "-c", "\"${BREW_GUNICORN_PATH}\" -w 1 --threads 4 -b 0.0.0.0:5000 app:app"]

# syntax=docker/dockerfile:1
ARG UID=1000

FROM python:3.10 as build

# RUN mount cache for multi-arch: https://github.com/docker/buildx/issues/549#issuecomment-1788297892
ARG TARGETARCH
ARG TARGETVARIANT

WORKDIR /app

# Install under /root/.local
ENV PIP_USER="true"
ARG PIP_NO_WARN_SCRIPT_LOCATION=0
ARG PIP_ROOT_USER_ACTION="ignore"

# Install build dependencies
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends python3-launchpadlib git curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install PyTorch and TensorFlow
# The versions must align and be in sync with the requirements_linux_docker.txt
# hadolint ignore=SC2102
RUN --mount=type=cache,id=pip-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/root/.cache/pip \
    pip install -U --extra-index-url https://download.pytorch.org/whl/cu121 --extra-index-url https://pypi.nvidia.com \
    torch==2.1.2 torchvision==0.16.2 \
    xformers==0.0.23.post1 \
    # Why [and-cuda]: https://github.com/tensorflow/tensorflow/issues/61468#issuecomment-1759462485
    tensorflow[and-cuda]==2.14.0 \
    ninja \
    pip setuptools wheel

# Install requirements
RUN --mount=type=cache,id=pip-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/root/.cache/pip \
    --mount=source=requirements_linux_docker.txt,target=requirements_linux_docker.txt \
    --mount=source=requirements.txt,target=requirements.txt \
    --mount=source=setup/docker_setup.py,target=setup.py \
    pip install -r requirements_linux_docker.txt -r requirements.txt && \
    # Replace pillow with pillow-simd
    pip uninstall -y pillow && \
    CC="cc -mavx2" pip install -U --force-reinstall pillow-simd

FROM python:3.10 as final

ARG UID

WORKDIR /app

# Install runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends libgl1 libglib2.0-0 libgoogle-perftools-dev dumb-init && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Fix missing libnvinfer7
RUN ln -s /usr/lib/x86_64-linux-gnu/libnvinfer.so /usr/lib/x86_64-linux-gnu/libnvinfer.so.7 && \
    ln -s /usr/lib/x86_64-linux-gnu/libnvinfer_plugin.so /usr/lib/x86_64-linux-gnu/libnvinfer_plugin.so.7

# Create user
RUN groupadd -g $UID $UID && \
    useradd -l -u $UID -g $UID -m -s /bin/sh -N $UID

# Copy dist and support arbitrary user ids (OpenShift best practice)
COPY --chown=$UID:0 --chmod=775 \
    --from=build /root/.local /home/$UID/.local
COPY --chown=$UID:0 --chmod=775 . .

ENV PATH="/home/$UID/.local/bin:$PATH"
ENV PYTHONPATH="${PYTHONPATH}:/home/$UID/.local/lib/python3.10/site-packages" 
ENV LD_PRELOAD=libtcmalloc.so
ENV PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

# Create directories with correct permissions
RUN install -d -m 775 -o $UID -g 0 /dataset && \
    install -d -m 775 -o $UID -g 0 /licenses && \
    install -d -m 775 -o $UID -g 0 /app

# Copy licenses (OpenShift Policy)
COPY --chmod=775 LICENSE.md /licenses/LICENSE.md

VOLUME [ "/dataset" ]

USER $UID

STOPSIGNAL SIGINT

# Use dumb-init as PID 1 to handle signals properly
ENTRYPOINT ["dumb-init", "--"]
CMD ["python3", "kohya_gui.py", "--listen", "0.0.0.0", "--server_port", "7860"]
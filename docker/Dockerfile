FROM docker.io/library/golang:1.24.0
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"
ENV PATH="/workspace/.venv/bin:${PATH}"

COPY entrypoint /entrypoint

CMD ["/entrypoint"]

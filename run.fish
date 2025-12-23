docker run -it --user 0 --gpus all --name e2a-gui -p 7860:7860 \
    -v "/home/admin/Documents/tts/ebooks:/app/ebooks" \
    -v "/home/admin/Documents/tts/audiobooks:/app/audiobooks" \
    -v "/home/admin/Documents/tts/voices:/app/voices" \
    -v "/home/admin/Documents/tts/cache:/opt/cache" \
    -v "/drive/cache/dot-cache/uv:/opt/cache/uv" \
    -v "/drive/cache/dot-cache/huggingface:/opt/cache/huggingface" \
    -v "/drive/AI/dicdir:/root/.local/share/unidic:ro" \
    -v "/drive/AI/stanza:/app/ebook2audiobook/models/stanza" \
    -v (pwd)/app.py:/app/ebook2audiobook/app.py:ro \
    -e STANZA_RESOURCES_DIR="/app/ebook2audiobook/models/stanza" \
    -e PYTHONUNBUFFERED=1 \
    -e PYTHONFAULTHANDLER=1 \
    -e HF_HUB_OFFLINE=1 \
    -e UV_CACHE_DIR="/opt/cache/uv" \
    -e UNIDIC_DIR="/root/.local/share/unidic" \
    -e GRADIO_SERVER_NAME="0.0.0.0" \
    -e GRADIO_SERVER_PORT="7860" \
    ebook2audiobook:cu121 \
    /opt/venv/bin/python -u -X faulthandler app.py

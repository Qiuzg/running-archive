"""Durable sync notifications consumed by an unprivileged API and systemd worker."""
from pathlib import Path
import time
import uuid
from .build_atlas import build, publish
from .build_thumbnails import build as build_thumbnails

QUEUE = Path(__file__).resolve().parent / 'snapshot-queue'


def request_refresh(queue=QUEUE):
    queue.mkdir(parents=True, exist_ok=True)
    (queue / uuid.uuid4().hex).touch()


def refresh(queue=QUEUE, output=Path('dist/generated')):
    # Merge a burst of HealthKit requests. Requests arriving during generation
    # retain their own marker and cause another run, so updates cannot be lost.
    time.sleep(10)
    markers = list(queue.iterdir()) if queue.exists() else []
    database = Path(__file__).with_name('running.db')
    publish(build(database), output / 'atlas.json')
    build_thumbnails(database, output / 'thumbnails.json')
    for marker in markers:
        marker.unlink(missing_ok=True)


if __name__ == '__main__':
    refresh()

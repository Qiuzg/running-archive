"""Bounded route previews for list views; stored/detail coordinates stay untouched."""
from heapq import heappop, heappush
from functools import lru_cache


def compact_preview(points, limit):
    # Content-based keys also invalidate when HealthKit updates an existing route.
    key = tuple((p[0], p[1]) for p in points)
    return [list(p) for p in _cached_preview(key, limit)]


@lru_cache(maxsize=64)
def _cached_preview(points, limit):
    if len(points) <= limit:
        return tuple((round(p[0], 6), round(p[1], 6)) for p in points)
    # Split the segment with the largest geometric error first, retaining bends
    # instead of dropping every nth point. Always retain both endpoints.
    selected = {0, len(points) - 1}
    segments = []

    def push(start, end):
        if end <= start + 1:
            return
        ax, ay = points[start][:2]
        bx, by = points[end][:2]
        dx, dy = bx - ax, by - ay
        length = dx * dx + dy * dy
        error, index = -1, start + 1
        for i in range(start + 1, end):
            x, y = points[i][:2]
            t = max(0, min(1, ((x - ax) * dx + (y - ay) * dy) / length)) if length else 0
            distance = (x - ax - t * dx) ** 2 + (y - ay - t * dy) ** 2
            if distance > error:
                error, index = distance, i
        if error > 0:
            heappush(segments, (-error, start, end, index))

    push(0, len(points) - 1)
    while segments and len(selected) < limit:
        _, start, end, index = heappop(segments)
        selected.add(index)
        push(start, index)
        push(index, end)
    return tuple((round(points[i][0], 6), round(points[i][1], 6)) for i in sorted(selected))

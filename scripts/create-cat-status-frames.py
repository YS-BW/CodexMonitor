#!/usr/bin/env python3
"""Build deterministic 56×36 monochrome menu-bar frames from the source sheet."""

from pathlib import Path
from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "docs/images/cat-sprites/cat-status-sprite-sheet-transparent.png"
OUTPUT = ROOT / "Sources/CodexMonitor/Resources/CatFrames"
PREVIEW = ROOT / "docs/images/cat-sprites/cat-status-frames-preview.png"
TRANSITION_PREVIEW = ROOT / "docs/images/cat-sprites/elthen-transition-frames-preview.png"

ROWS = ("idle", "thinking", "cat", "waiting")
FRAME_COUNT = 5
FRAME_SIZE = (56, 36)
MAX_CONTENT = (52, 30)
ELTHEN_ROWS = {
    "idle": 4,
    "thinking": 4,
    "working": 8,
    "waiting": 6,
}
TRANSITION_FRAME_COUNT = 6


def foreground_mask(cell: Image.Image) -> Image.Image:
    rgba = cell.convert("RGBA")
    mask = Image.new("L", rgba.size, 0)
    source = rgba.load()
    target = mask.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = source[x, y]
            if alpha > 56 and red + green + blue < 260:
                target[x, y] = 255
    bounds = mask.getbbox()
    if bounds is None:
        raise RuntimeError("No cat pixels found in a sprite cell")
    mask = mask.crop(bounds)
    pixels = mask.load()
    visited: set[tuple[int, int]] = set()
    components: list[list[tuple[int, int]]] = []
    for y in range(mask.height):
        for x in range(mask.width):
            if pixels[x, y] == 0 or (x, y) in visited:
                continue
            component: list[tuple[int, int]] = []
            stack = [(x, y)]
            visited.add((x, y))
            while stack:
                point = stack.pop()
                component.append(point)
                px, py = point
                for ny in range(max(0, py - 1), min(mask.height, py + 2)):
                    for nx in range(max(0, px - 1), min(mask.width, px + 2)):
                        if pixels[nx, ny] > 0 and (nx, ny) not in visited:
                            visited.add((nx, ny))
                            stack.append((nx, ny))
            components.append(component)

    largest_size = max(map(len, components))
    minimum_size = max(48, round(largest_size * 0.02))
    cleaned = Image.new("L", mask.size, 0)
    cleaned_pixels = cleaned.load()
    for component in components:
        if len(component) >= minimum_size:
            for x, y in component:
                cleaned_pixels[x, y] = 255
    return cleaned.crop(cleaned.getbbox())


def place_frame(mask: Image.Image, scale: float) -> Image.Image:
    width = max(1, round(mask.width * scale))
    height = max(1, round(mask.height * scale))
    resized = mask.resize((width, height), Image.Resampling.NEAREST)
    canvas = Image.new("RGBA", FRAME_SIZE, (0, 0, 0, 0))
    silhouette = Image.new("RGBA", resized.size, (0, 0, 0, 255))
    silhouette.putalpha(resized)
    x = (FRAME_SIZE[0] - width) // 2
    y = FRAME_SIZE[1] - height - 2
    canvas.alpha_composite(silhouette, (x, y))
    return canvas


def content_bounds(frame: Image.Image) -> tuple[int, int, int, int]:
    bounds = frame.getchannel("A").getbbox()
    if bounds is None:
        raise RuntimeError("No cat pixels found in a rendered frame")
    return bounds


def transformed_frame(frame: Image.Image, scale_x: float, scale_y: float, y_offset: int) -> Image.Image:
    bounds = content_bounds(frame)
    cropped = frame.crop(bounds)
    width = max(1, round(cropped.width * scale_x))
    height = max(1, round(cropped.height * scale_y))
    resized = cropped.resize((width, height), Image.Resampling.NEAREST)
    canvas = Image.new("RGBA", FRAME_SIZE, (0, 0, 0, 0))
    x = (FRAME_SIZE[0] - width) // 2
    baseline = FRAME_SIZE[1] - 2
    y = baseline - height + y_offset
    canvas.alpha_composite(resized, (x, y))
    return canvas


def make_transition_frames(target_frames: list[Image.Image]) -> list[Image.Image]:
    if not target_frames:
        return []

    target = target_frames[0]
    easing = [
        (1.18, 0.74, 4),
        (1.12, 0.84, 3),
        (1.06, 0.94, 1),
        (0.98, 1.06, -1),
        (1.02, 1.00, 0),
    ]
    transition = [
        transformed_frame(target, scale_x, scale_y, y_offset)
        for scale_x, scale_y, y_offset in easing
    ]
    transition.append(target_frames[1] if len(target_frames) > 1 else target)
    return transition[:TRANSITION_FRAME_COUNT]


def main() -> None:
    sheet = Image.open(SOURCE).convert("RGBA")
    OUTPUT.mkdir(parents=True, exist_ok=True)

    frames_by_row: list[list[Image.Image]] = []
    for row in range(len(ROWS)):
        row_frames: list[Image.Image] = []
        top = round(row * sheet.height / len(ROWS))
        bottom = round((row + 1) * sheet.height / len(ROWS))
        for column in range(FRAME_COUNT):
            left = round(column * sheet.width / FRAME_COUNT)
            right = round((column + 1) * sheet.width / FRAME_COUNT)
            row_frames.append(foreground_mask(sheet.crop((left, top, right, bottom))))
        frames_by_row.append(row_frames)

    finished: list[list[Image.Image]] = []
    for name, masks in zip(ROWS, frames_by_row):
        max_width = max(mask.width for mask in masks)
        max_height = max(mask.height for mask in masks)
        scale = min(MAX_CONTENT[0] / max_width, MAX_CONTENT[1] / max_height)
        rendered = [place_frame(mask, scale) for mask in masks]
        finished.append(rendered)
        for index, frame in enumerate(rendered):
            frame.save(OUTPUT / f"{name}-frame-{index}.png", optimize=True)

    for state, count in ELTHEN_ROWS.items():
        prefix = f"elthen-{state}-frame"
        target_frames = [
            Image.open(OUTPUT / f"{prefix}-{index}.png").convert("RGBA")
            for index in range(count)
            if (OUTPUT / f"{prefix}-{index}.png").exists()
        ]
        for index, frame in enumerate(make_transition_frames(target_frames)):
            frame.save(OUTPUT / f"elthen-transition-{state}-frame-{index}.png", optimize=True)

    preview_scale = 6
    transition_preview = Image.new(
        "RGB",
        (
            FRAME_SIZE[0] * TRANSITION_FRAME_COUNT * preview_scale,
            FRAME_SIZE[1] * len(ELTHEN_ROWS) * preview_scale,
        ),
        "white",
    )
    transition_draw = ImageDraw.Draw(transition_preview)
    for row, state in enumerate(ELTHEN_ROWS):
        for column in range(TRANSITION_FRAME_COUNT):
            frame = Image.open(
                OUTPUT / f"elthen-transition-{state}-frame-{column}.png"
            ).convert("RGBA")
            enlarged = frame.resize(
                (FRAME_SIZE[0] * preview_scale, FRAME_SIZE[1] * preview_scale),
                Image.Resampling.NEAREST,
            )
            transition_preview.paste(
                enlarged,
                (
                    column * FRAME_SIZE[0] * preview_scale,
                    row * FRAME_SIZE[1] * preview_scale,
                ),
                enlarged,
            )
        transition_draw.line(
            (
                0,
                (row + 1) * FRAME_SIZE[1] * preview_scale - 1,
                transition_preview.width,
                (row + 1) * FRAME_SIZE[1] * preview_scale - 1,
            ),
            fill="#dddddd",
        )
    transition_preview.save(TRANSITION_PREVIEW, optimize=True)

    preview = Image.new(
        "RGB",
        (
            FRAME_SIZE[0] * FRAME_COUNT * preview_scale,
            FRAME_SIZE[1] * len(ROWS) * preview_scale,
        ),
        "white",
    )
    draw = ImageDraw.Draw(preview)
    for row, frames in enumerate(finished):
        for column, frame in enumerate(frames):
            enlarged = frame.resize(
                (FRAME_SIZE[0] * preview_scale, FRAME_SIZE[1] * preview_scale),
                Image.Resampling.NEAREST,
            )
            preview.paste(
                enlarged,
                (
                    column * FRAME_SIZE[0] * preview_scale,
                    row * FRAME_SIZE[1] * preview_scale,
                ),
                enlarged,
            )
        draw.line(
            (
                0,
                (row + 1) * FRAME_SIZE[1] * preview_scale - 1,
                preview.width,
                (row + 1) * FRAME_SIZE[1] * preview_scale - 1,
            ),
            fill="#dddddd",
        )
    preview.save(PREVIEW, optimize=True)


if __name__ == "__main__":
    main()

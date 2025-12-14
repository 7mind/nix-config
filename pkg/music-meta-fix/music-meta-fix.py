#!/usr/bin/env python3

import argparse
import os
import sys
from pathlib import Path
from typing import Optional

import mutagen
from mutagen.easyid3 import EasyID3
from mutagen.easymp4 import EasyMP4Tags
from mutagen.id3 import ID3NoHeaderError

MUSIC_EXTENSIONS = {'.mp3', '.flac', '.ogg', '.opus', '.m4a', '.mp4', '.wma', '.wav', '.aiff', '.aif'}


def get_easy_tags(filepath: Path) -> Optional[mutagen.FileType]:
    """Load file with easy tags interface for unified access."""
    try:
        audio = mutagen.File(filepath, easy=True)
        if audio is None:
            return None
        return audio
    except Exception as e:
        print(f"Error reading {filepath}: {e}", file=sys.stderr)
        return None


def get_title(audio: mutagen.FileType) -> Optional[str]:
    """Extract title from audio file tags."""
    title = audio.get('title')
    if title:
        return title[0] if isinstance(title, list) else title
    return None


def get_album(audio: mutagen.FileType) -> Optional[str]:
    """Extract album from audio file tags."""
    album = audio.get('album')
    if album:
        return album[0] if isinstance(album, list) else album
    return None


def is_missing_metadata(audio: mutagen.FileType) -> bool:
    """Check if file is missing title or both title and album."""
    title = get_title(audio)
    album = get_album(audio)
    return not title or not album


def enumerate_music_files(directory: Path, recursive: bool) -> list[Path]:
    """Find all music files in directory."""
    files = []
    if recursive:
        for filepath in directory.rglob('*'):
            if filepath.is_file() and filepath.suffix.lower() in MUSIC_EXTENSIONS:
                files.append(filepath)
    else:
        for filepath in directory.iterdir():
            if filepath.is_file() and filepath.suffix.lower() in MUSIC_EXTENSIONS:
                files.append(filepath)
    return sorted(files)


def set_metadata(filepath: Path, audio: mutagen.FileType) -> None:
    """Set title to filename (without extension) and album to parent directory name."""
    title = filepath.stem
    album = filepath.parent.name

    audio['title'] = title
    audio['album'] = album
    audio.save()


def main() -> int:
    parser = argparse.ArgumentParser(
        description='Find and fix music files with missing metadata'
    )
    parser.add_argument(
        'directory',
        nargs='?',
        default='.',
        help='Directory to scan (default: current directory)'
    )
    parser.add_argument(
        '-r', '--recurse',
        action='store_true',
        help='Recursively scan subdirectories'
    )
    parser.add_argument(
        '-a', '--apply',
        action='store_true',
        help='Apply fixes: set title to filename, album to directory name'
    )

    args = parser.parse_args()
    directory = Path(args.directory).resolve()

    if not directory.is_dir():
        print(f"Error: {directory} is not a directory", file=sys.stderr)
        return 1

    music_files = enumerate_music_files(directory, args.recurse)

    if not music_files:
        print("No music files found")
        return 0

    files_to_fix: list[tuple[Path, mutagen.FileType]] = []

    for filepath in music_files:
        audio = get_easy_tags(filepath)
        if audio is None:
            continue

        if is_missing_metadata(audio):
            files_to_fix.append((filepath, audio))

    if not files_to_fix:
        print("All music files have complete metadata")
        return 0

    print(f"Found {len(files_to_fix)} file(s) with missing metadata:\n")

    for filepath, audio in files_to_fix:
        title = get_title(audio) or '<missing>'
        album = get_album(audio) or '<missing>'
        rel_path = filepath.relative_to(directory) if filepath.is_relative_to(directory) else filepath
        print(f"  {rel_path}")
        print(f"    Title: {title}")
        print(f"    Album: {album}")

        if args.apply:
            new_title = filepath.stem
            new_album = filepath.parent.name
            print(f"    -> Setting title: {new_title}")
            print(f"    -> Setting album: {new_album}")
            try:
                set_metadata(filepath, audio)
                print("    [OK]")
            except Exception as e:
                print(f"    [FAILED] {e}", file=sys.stderr)
        print()

    if not args.apply:
        print("Run with --apply to fix these files")

    return 0


if __name__ == '__main__':
    sys.exit(main())

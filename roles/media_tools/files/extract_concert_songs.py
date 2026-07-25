#!/usr/bin/env python3
# One-off extraction of individual songs from the two Malón concert MKVs
# into opus files for the Navidrome library, replacing the hand-built rips
# that were tagged outside of Ansible via the old tag_malon.sh. Re-run is
# safe: it always regenerates each album's output directory from scratch
# from the current state of the MKVs.
#
# Track titles below are reused verbatim from the already-curated Navidrome
# filenames where a track already existed there, rather than re-derived
# from the raw MKV chapter strings, so hand-fixed accents/casing aren't
# regressed. The two chapters that were previously omitted (a crowd chant,
# an outro/credits reel) get titles taken directly from their MKV chapter
# string instead, since there's no prior curation to preserve.
#
# Also rewrites each MKV's chapter titles in place (mkvpropedit) to strip
# the inconsistent "(Hermética Cover)" / "(Hermética cover)" annotations,
# matching how the Navidrome library already names cover songs.
import base64
import json
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

from mutagen.flac import Picture
from mutagen.oggopus import OggOpus

CONCERTS_DIR = Path("/mnt/ssd2tb/media/concerts_mkv")
OUT_DIR = Path("/mnt/ssd2tb/media/concert_extracts")
COVERS_DIR = OUT_DIR / ".covers"

COVER_ANNOTATION_RE = re.compile(r"\s*\([^)]*\bcover\b[^)]*\)", re.IGNORECASE)

ALBUMS = {
    "Malon - 360.mkv": {
        "album": "Malón 360",
        "date": "2013",
        "out_subdir": "2013 - 360",
        "cover": COVERS_DIR / "360.jpg",
        "tracks": [
            ("01", "01 Intro.opus", "Intro"),
            ("02", "02 Malón Mestizo.opus", "Malón Mestizo"),
            ("03", "03 Castigador por Herencia.opus", "Castigador por Herencia"),
            ("04", "04 Mendigos.opus", "Mendigos"),
            ("05", "05 Síntoma de la Infección.opus", "Síntoma de la Infección"),
            ("06", "06 Nido de Almas.opus", "Nido de Almas"),
            ("07", "07 Grito de Pilagá.opus", "Grito de Pilagá"),
            ("08", "08 Revolución Nacional.opus", "Revolución Nacional"),
            ("09", "09 Yo No Lo Haré.opus", "Yo No Lo Haré"),
            ("10", "10 Robó un Auto.opus", "Robó un Auto"),
            ("11", "11 Baila la Hinchada.opus", "Baila la Hinchada"),
            ("12", "12 Cancha de Lodo.opus", "Cancha de Lodo"),
            ("13", "13 Víctimas del Vaciamiento.opus", "Víctimas del Vaciamiento"),
            ("14", "14 Orgías Bacanales.opus", "Orgías Bacanales"),
            ("15", "15 30.000 Plegarias.opus", "30.000 Plegarias"),
            ("16", "16 Vida Impersonal.opus", "Vida Impersonal"),
            ("17", "17 Gatillo Fácil.opus", "Gatillo Fácil"),
            ("18", "18 Tú Eres Su Seguridad.opus", "Tú Eres Su Seguridad"),
            ("19", "19 Sobaco Ilustrado.opus", "Sobaco Ilustrado"),
            ("20", "20 Bajo el Dominio Danzante.opus", "Bajo el Dominio Danzante"),
            ("21", "21 Sepulcro Civil.opus", "Sepulcro Civil"),
            ("22", "22 Espíritu Combativo.opus", "Espíritu Combativo"),
            ("23", "23 Si Se Calla el Cantor.opus", "Si Se Calla el Cantor"),
        ],
    },
    "Malon - El Regreso Mas Esperado 2012.mkv": {
        "album": "Malón - El regreso más esperado",
        "date": "2012",
        "out_subdir": "2012 - El regreso más esperado",
        "cover": COVERS_DIR / "regreso.jpg",
        "tracks": [
            ("00", "00 Intro.opus", "Intro"),
            ("01", "Malón - El regreso más esperado - 01 - Sintoma de la infección.opus", "Sintoma de la infección"),
            ("02", "Malón - El regreso más esperado - 02 - Culto siniestro.opus", "Culto siniestro"),
            ("03", "Malón - El regreso más esperado - 03 - Castigador por herencia.opus", "Castigador por herencia"),
            ("04", "Malón - El regreso más esperado - 04 - Hipotecado.opus", "Hipotecado"),
            ("05", "Malón - El regreso más esperado - 05 - Cancha de lodo.opus", "Cancha de lodo"),
            ("06", "Malón - El regreso más esperado - 06 - Evitando el ablande.opus", "Evitando el ablande"),
            ("07", "Malón - El regreso más esperado - 07 - Judas de oficio.opus", "Judas de oficio"),
            ("08", "Malón - El regreso más esperado - 08 - Bajo el dominio danzante.opus", "Bajo el dominio danzante"),
            ("09", "Malón - El regreso más esperado - 09 - Grito de pilaga.opus", "Grito de pilaga"),
            ("10", "Malón - El regreso más esperado - 10 - Gil trabajador.opus", "Gil trabajador"),
            ("11", "Malón - El regreso más esperado - 11 - Memorias de siglos.opus", "Memorias de siglos"),
            ("12", "Malón - El regreso más esperado - 12 - 30.000 plegarias (versión acústica).opus", "30.000 plegarias (versión acústica)"),
            ("13", "Malón - El regreso más esperado - 13 - Craneo candente.opus", "Craneo candente"),
            ("14", "Malón - El regreso más esperado - 14 - Gatillo fácil.opus", "Gatillo fácil"),
            ("15", "Malón - El regreso más esperado - 15 - 30.000 plegarias.opus", "30.000 plegarias"),
            ("16", "Malón - El regreso más esperado - 16 - Malón mestizo.opus", "Malón mestizo"),
            ("17", "Malón - El regreso más esperado - 17 - Tú eres su seguridad.opus", "Tú eres su seguridad"),
            ("18", "Malón - El regreso más esperado - 18 - Soy de la esquina.opus", "Soy de la esquina"),
            ("19", "Malón - El regreso más esperado - 19 - Outro - Créditos.opus", "Outro - Créditos"),
        ],
    },
}


def get_chapters(mkv_path):
    """Returns [(start_timestamp, end_timestamp, raw_title), ...] in chapter order."""
    xml_text = subprocess.run(
        ["mkvextract", str(mkv_path), "chapters", "-"],
        capture_output=True, text=True, check=True,
    ).stdout
    root = ET.fromstring(xml_text)
    chapters = []
    for atom in root.iter("ChapterAtom"):
        start = atom.find("ChapterTimeStart").text
        end = atom.find("ChapterTimeEnd").text
        title = atom.find("./ChapterDisplay/ChapterString").text
        chapters.append((start, end, title))
    return chapters


def rewrite_chapter_titles(mkv_path, chapters):
    """Strips cover annotations from chapter titles and applies in place via mkvpropedit."""
    root = ET.Element("Chapters")
    edition = ET.SubElement(root, "EditionEntry")
    ET.SubElement(edition, "EditionFlagDefault").text = "1"
    for uid, (start, end, raw_title) in enumerate(chapters, start=1):
        cleaned = COVER_ANNOTATION_RE.sub("", raw_title).strip()
        atom = ET.SubElement(edition, "ChapterAtom")
        ET.SubElement(atom, "ChapterUID").text = str(uid)
        ET.SubElement(atom, "ChapterTimeStart").text = start
        ET.SubElement(atom, "ChapterTimeEnd").text = end
        display = ET.SubElement(atom, "ChapterDisplay")
        ET.SubElement(display, "ChapterString").text = cleaned
        ET.SubElement(display, "ChapterLanguage").text = "und"

    with tempfile.NamedTemporaryFile(mode="wb", suffix=".xml", delete=False) as f:
        tree = ET.ElementTree(root)
        ET.indent(tree)
        tree.write(f, encoding="utf-8", xml_declaration=True)
        tmp_path = f.name

    subprocess.run(["mkvpropedit", str(mkv_path), "--chapters", tmp_path], check=True)
    Path(tmp_path).unlink()


def extract_track(mkv_path, start, end, out_path):
    out_path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "warning",
            "-ss", start, "-to", end,
            "-i", str(mkv_path),
            "-map", "0:a:0", "-ac", "2",
            "-c:a", "libopus", "-b:a", "160k", "-vbr", "on", "-ar", "48000",
            str(out_path),
        ],
        check=True,
    )


def tag_track(out_path, title, artist, album, date, track_num, cover_path):
    f = OggOpus(str(out_path))
    f["title"] = title
    f["artist"] = artist
    f["albumartist"] = artist
    f["album"] = album
    f["tracknumber"] = track_num
    f["date"] = date

    if cover_path.exists():
        pic = Picture()
        pic.data = cover_path.read_bytes()
        pic.type = 3  # cover front
        pic.mime = "image/jpeg"
        pic.desc = "Cover"
        f["metadata_block_picture"] = [base64.b64encode(pic.write()).decode("ascii")]

    f.save()


def main():
    for mkv_name, album in ALBUMS.items():
        mkv_path = CONCERTS_DIR / mkv_name
        chapters = get_chapters(mkv_path)
        tracks = album["tracks"]
        if len(chapters) != len(tracks):
            raise SystemExit(
                f"{mkv_name}: expected {len(tracks)} chapters, found {len(chapters)} "
                "- track table is out of sync with the MKV, aborting"
            )

        out_album_dir = OUT_DIR / album["out_subdir"]
        for (start, end, _raw_title), (track_num, filename, tag_title) in zip(chapters, tracks):
            out_path = out_album_dir / filename
            print(f"{mkv_name}: extracting track {track_num} -> {filename}")
            extract_track(mkv_path, start, end, out_path)
            tag_track(out_path, tag_title, "Malón", album["album"], album["date"], track_num, album["cover"])

        rewrite_chapter_titles(mkv_path, chapters)
        print(f"{mkv_name}: chapter titles cleaned in place")


if __name__ == "__main__":
    main()

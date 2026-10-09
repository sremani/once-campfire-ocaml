#!/usr/bin/env python3
"""Regenerate lib/unicode_lower.ml from pinned Python Unicode 15.0 data."""
import argparse
import pathlib
import unicodedata

EXPECTED_UNICODE_VERSION = "15.0.0"
OUTPUT = pathlib.Path(__file__).resolve().parents[1] / "lib/unicode_lower.ml"


def generated():
    if unicodedata.unidata_version != EXPECTED_UNICODE_VERSION:
        raise SystemExit(
            f"need Unicode {EXPECTED_UNICODE_VERSION}, got {unicodedata.unidata_version}"
        )
    lines = [
        f"(* Unicode lowercase mappings from Python unicodedata {EXPECTED_UNICODE_VERSION};\n"
        "   Uutf handles UTF-8 decoding and encoding. *)\n",
        "let mappings = [|\n",
    ]
    for codepoint in range(0x80, 0x110000):
        character = chr(codepoint)
        lowercase = character.lower()
        if lowercase != character:
            encoded = "".join(f"\\x{byte:02x}" for byte in lowercase.encode("utf-8"))
            lines.append(f'  (0x{codepoint:x},"{encoded}");\n')
    lines.append(
        "|]\n"
        "let find cp =\n"
        "  let lo=ref 0 and hi=ref (Array.length mappings-1) in\n"
        "  let result=ref None in\n"
        "  while !lo <= !hi do\n"
        "    let mid=(!lo + !hi)/2 in\n"
        "    let key,value=mappings.(mid) in\n"
        "    if key=cp then (result:=Some value; lo:= !hi+1)\n"
        "    else if key<cp then lo:=mid+1 else hi:=mid-1\n"
        "  done; !result\n"
        "let lowercase s =\n"
        "  if String.for_all (fun c -> Char.code c<128) s then String.lowercase_ascii s else\n"
        "  let b=Buffer.create (String.length s) in\n"
        "  let add _ _ = function\n"
        "    | `Malformed bytes -> Buffer.add_string b bytes; ()\n"
        "    | `Uchar u ->\n"
        "      let cp=Uchar.to_int u in\n"
        "      if cp<128 then Buffer.add_char b (Char.lowercase_ascii (Char.chr cp))\n"
        "      else match find cp with Some value -> Buffer.add_string b value\n"
        "        | None -> Uutf.Buffer.add_utf_8 b u\n"
        "  in Uutf.String.fold_utf_8 add () s; Buffer.contents b\n"
        "\n"
        "let whitespace cp =\n"
        "  List.mem cp [0x9;0xa;0xb;0xc;0xd;0x20;0x85;0xa0;0x1680;\n"
        "    0x2028;0x2029;0x202f;0x205f;0x3000]\n"
        "  || (cp>=0x2000 && cp<=0x200a)\n"
        "let blank s =\n"
        "  Uutf.String.fold_utf_8 (fun blank _ -> function\n"
        "    | `Uchar u -> blank && whitespace (Uchar.to_int u)\n"
        "    | `Malformed _ -> false) true s\n"
    )
    return "".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = generated()
    if args.check:
        if OUTPUT.read_text() != source:
            raise SystemExit(f"{OUTPUT} is stale")
        print("Unicode lowercase table matches Unicode 15.0.0")
    else:
        OUTPUT.write_text(source)


if __name__ == "__main__":
    main()

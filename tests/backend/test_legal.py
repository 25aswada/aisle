import re
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from backend.app.legal import CONTACT_EMAIL, PRIVACY, SUMMARY, TERMS
from backend.app.main import app

SWIFT = Path(__file__).resolve().parents[2] / "ios" / "Aisle" / "Account" / "LegalText.swift"


def swift_document(name):
    """The (title, body) sections of one document in the app's LegalText.swift."""
    source = SWIFT.read_text()
    start = source.index(f"static let {name} = Document(")
    end = source.index("\n    ])", start)
    sections = re.findall(r'Section\(title: "(.*?)", body: """\n(.*?)\n\s*"""\)', source[start:end], re.S)
    return [(title, "\n".join(line.removeprefix("        ") for line in body.split("\n"))
             .replace(r"\(contactEmail)", CONTACT_EMAIL)) for title, body in sections]


@pytest.mark.skipif(not SWIFT.exists(), reason="the iOS app isn't in this checkout")
@pytest.mark.parametrize("name, sections", [("terms", TERMS), ("privacy", PRIVACY)])
def test_the_app_and_the_website_say_the_same_thing(name, sections):
    assert swift_document(name) == sections


@pytest.mark.skipif(not SWIFT.exists(), reason="the iOS app isn't in this checkout")
def test_the_summary_matches():
    source = SWIFT.read_text()
    assert re.findall(r'\("[a-z.]+", "(.*?)"\)', source[source.index("static let summary"):]) [:len(SUMMARY)] == SUMMARY


@pytest.mark.parametrize("path, heading", [
    ("/privacy", "Privacy Policy"), ("/terms", "Terms of Service"), ("/support", "Aisle Support"),
])
def test_public_pages(path, heading):
    with TestClient(app) as client:
        page = client.get(path)
    assert page.status_code == 200
    assert page.headers["content-type"].startswith("text/html")
    assert f"<h1>{heading}</h1>" in page.text and CONTACT_EMAIL in page.text

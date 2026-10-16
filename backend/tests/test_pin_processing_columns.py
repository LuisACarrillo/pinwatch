"""Flujo 2 en pins: status, processed_key y thumbnail_key, y el suscriptor de SNS que los guarda."""

import json

import pytest

import image_events
import main

ORIGINAL = "originals/abc/atardecer.jpg"


def create_pin(client, object_key=ORIGINAL):
    token = client.post(
        "/auth/register", json={"username": "flujo2", "email": "flujo2@example.com", "password": "contrasena-segura"}
    ).json()["access_token"]
    response = client.post(
        "/pins",
        json={"title": "Atardecer", "category": "photography", "object_key": object_key},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 201
    return response.json()


def sns_event(event_type, **data):
    """Evento con la forma con la que SNS invoca a una Lambda suscrita."""
    message = {"event_type": event_type, "timestamp": "2026-10-16T00:00:00+00:00", "data": data}
    return {"Records": [{"EventSource": "aws:sns", "Sns": {"Message": json.dumps(message)}}]}


def test_new_pin_is_pending_with_keys_derived_from_object_key(client):
    pin = create_pin(client)
    item = client.get("/feed").json()["items"][0]

    for result in (pin, item):
        assert result["status"] == "pending"
        assert result["processed_key"] == "processed/abc/atardecer.webp"
        assert result["thumbnail_key"] == "thumbnails/abc/atardecer.webp"


def test_pin_outside_originals_has_no_keys(client):
    pin = create_pin(client, object_key="otra/ruta/foto.jpg")
    assert (pin["processed_key"], pin["thumbnail_key"]) == (None, None)


def test_processed_event_marks_the_pin(client):
    pin = create_pin(client)

    result = main.handler(
        sns_event(
            "imagen_procesada",
            object_key=ORIGINAL,
            status="processed",
            processed_key="processed/abc/atardecer.webp",
            thumbnail_key="thumbnails/abc/atardecer.webp",
        ),
        None,
    )

    assert result == {"results": [{"object_key": ORIGINAL, "status": "processed", "updated": 1}]}
    for item in (client.get("/feed").json()["items"][0], client.get(f"/pins/{pin['id']}").json()):
        assert item["status"] == "processed"
        assert item["thumbnail_key"] == "thumbnails/abc/atardecer.webp"


def test_rejected_event_clears_the_keys(client):
    pin = create_pin(client)

    main.handler(sns_event("imagen_rechazada", object_key=ORIGINAL, status="rejected", reason="not_an_image"), None)

    detail = client.get(f"/pins/{pin['id']}").json()
    assert detail["status"] == "rejected"
    assert (detail["processed_key"], detail["thumbnail_key"]) == (None, None)


def test_event_before_the_pin_exists_is_raised_for_retry(client):
    with pytest.raises(image_events.PinNotFoundYet):
        main.handler(sns_event("imagen_rechazada", object_key=ORIGINAL, status="rejected", reason="too_large"), None)


def test_other_topic_events_are_ignored(client):
    result = main.handler(sns_event("pin.liked", pin_id="123"), None)
    assert result == {"results": [{"event_type": "pin.liked", "status": "ignored"}]}

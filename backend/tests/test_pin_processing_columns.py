"""Columnas del Flujo 2 en pins: status, processed_key y thumbnail_key."""


def create_pin(client, title="Atardecer"):
    user = client.post(
        "/users",
        json={"username": "flujo2", "email": "flujo2@example.com"},
    ).json()
    response = client.post(
        "/pins",
        json={
            "user_id": user["id"],
            "title": title,
            "category": "photography",
            "object_key": "originals/abc/atardecer.jpg",
        },
    )
    assert response.status_code == 201
    return response.json()


def test_new_pin_is_pending_without_processed_keys(client):
    pin = create_pin(client)
    assert pin["status"] == "pending"
    assert pin["processed_key"] is None
    assert pin["thumbnail_key"] is None

    item = client.get("/feed").json()["items"][0]
    assert item["status"] == "pending"
    assert item["processed_key"] is None
    assert item["thumbnail_key"] is None


def test_feed_and_detail_return_processed_keys(client, test_db):
    pin = create_pin(client)
    test_db.execute(
        "UPDATE pins SET status = 'processed', processed_key = ?, thumbnail_key = ? WHERE id = ?;",
        ("processed/abc/atardecer.webp", "thumbnails/abc/atardecer.webp", pin["id"]),
    )
    test_db.commit()

    for item in (client.get("/feed").json()["items"][0], client.get(f"/pins/{pin['id']}").json()):
        assert item["status"] == "processed"
        assert item["processed_key"] == "processed/abc/atardecer.webp"
        assert item["thumbnail_key"] == "thumbnails/abc/atardecer.webp"

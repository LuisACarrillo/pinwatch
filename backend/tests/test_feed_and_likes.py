from uuid import uuid4
import sns


def test_feed_empty(client):
    response = client.get("/feed?page=1&limit=10")
    assert response.status_code == 200
    data = response.json()
    assert data["items"] == []
    assert data["total"] == 0
    assert data["page"] == 1
    assert data["total_pages"] == 1


def test_create_pin_and_paginated_feed(client, register):
    # 1. Crear usuario autor
    user_id, headers = register("alice", "alice@example.com")

    # 2. Crear pines en distintas categorías
    for i in range(5):
        category = "design" if i % 2 == 0 else "photography"
        p_res = client.post(
            "/pins",
            json={
                "title": f"Pin {i}",
                "description": f"Desc {i}",
                "category": category,
                "object_key": f"originals/{uuid4()}/img.jpg",
            },
            headers=headers,
        )
        assert p_res.status_code == 201
        assert p_res.json()["likes_count"] == 0

    # 3. Consulta paginada total
    feed_res = client.get("/feed?page=1&limit=3")
    assert feed_res.status_code == 200
    feed_data = feed_res.json()
    assert feed_data["total"] == 5
    assert len(feed_data["items"]) == 3
    assert feed_data["total_pages"] == 2
    assert feed_data["page"] == 1

    # Página 2
    feed_res2 = client.get("/feed?page=2&limit=3")
    assert feed_res2.status_code == 200
    feed_data2 = feed_res2.json()
    assert len(feed_data2["items"]) == 2

    # 4. Filtrar por categoría 'design' (3 elementos)
    cat_res = client.get("/feed?category=design&page=1&limit=10")
    assert cat_res.status_code == 200
    cat_data = cat_res.json()
    assert cat_data["total"] == 3
    for pin in cat_data["items"]:
        assert pin["category"] == "design"


def test_like_pin_increments_count_and_creates_notification(client, register, monkeypatch):
    # Capturar eventos SNS
    published_events = []

    def mock_publish_event(event_type, payload, subject=None):
        published_events.append({"event_type": event_type, "payload": payload, "subject": subject})
        return {"MessageId": "mock-msg-123"}

    monkeypatch.setattr(sns, "publish_event", mock_publish_event)

    # 1. Crear usuario dueño del pin
    user_id, headers = register("bob", "bob@example.com")

    # 2. Crear el pin
    p_res = client.post(
        "/pins",
        json={
            "title": "Inspiración Minimalista",
            "description": "Un buen diseño",
            "category": "arquitectura",
            "object_key": "originals/mock/img.jpg",
        },
        headers=headers,
    )
    pin_id = p_res.json()["id"]
    assert p_res.json()["likes_count"] == 0

    # 3. Dar like al pin (sin registrar usuario que da like, solo incrementa contador)
    like_res1 = client.post(f"/pins/{pin_id}/like", headers=headers)
    assert like_res1.status_code == 200
    data1 = like_res1.json()
    assert data1["pin_id"] == pin_id
    assert data1["likes_count"] == 1
    assert "Like registrado" in data1["message"]

    # Segundo like
    like_res2 = client.post(f"/pins/{pin_id}/like", headers=headers)
    assert like_res2.status_code == 200
    data2 = like_res2.json()
    assert data2["likes_count"] == 2

    # Verificar que el pin en /feed refleja los 2 likes
    pin_res = client.get(f"/pins/{pin_id}")
    assert pin_res.status_code == 200
    assert pin_res.json()["likes_count"] == 2

    # 4. Verificar que se creó notificación para el dueño del pin
    notif_res = client.get("/notifications", headers=headers)
    assert notif_res.status_code == 200
    notifs = notif_res.json()
    assert len(notifs) == 2
    assert notifs[0]["user_id"] == user_id
    assert notifs[0]["pin_id"] == pin_id
    assert "Inspiración Minimalista" in notifs[0]["message"]

    # 5. Verificar que se emitieron eventos SNS con tipo 'pin.liked'
    like_events = [e for e in published_events if e["event_type"] == "pin.liked"]
    assert len(like_events) == 2
    assert like_events[0]["payload"]["pin_id"] == pin_id
    assert like_events[0]["payload"]["user_id"] == user_id


def test_like_non_existent_pin_returns_404(client, register):
    _, headers = register("carol", "carol@example.com")
    res = client.post("/pins/non-existent-uuid/like", headers=headers)
    assert res.status_code == 404
    assert res.json()["detail"] == "Pin no encontrado."

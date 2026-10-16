def test_board_crud_lifecycle(client, register):
    # 1. Crear usuario
    user_id, headers = register("charlie", "charlie@example.com")

    # 2. Crear tablero
    b_res = client.post(
        "/boards",
        json={"name": "Mi Tablero Creativo", "description": "Colección de arte"},
        headers=headers,
    )
    assert b_res.status_code == 201
    board_data = b_res.json()
    board_id = board_data["id"]
    assert board_data["name"] == "Mi Tablero Creativo"
    assert board_data["pins_count"] == 0

    # 3. Listar tableros
    list_res = client.get(f"/boards?user_id={user_id}")
    assert list_res.status_code == 200
    boards = list_res.json()
    assert len(boards) == 1
    assert boards[0]["id"] == board_id

    # 4. Actualizar tablero
    up_res = client.put(
        f"/boards/{board_id}", json={"name": "Nuevo Nombre", "description": "Nueva desc"}, headers=headers
    )
    assert up_res.status_code == 200
    assert up_res.json()["name"] == "Nuevo Nombre"

    # 5. Obtener detalle de tablero (inicialmente vacío)
    det_res = client.get(f"/boards/{board_id}")
    assert det_res.status_code == 200
    assert det_res.json()["pins"] == []

    # 6. Eliminar tablero
    del_res = client.delete(f"/boards/{board_id}", headers=headers)
    assert del_res.status_code == 200

    # 7. Comprobar que ya no existe
    get_res = client.get(f"/boards/{board_id}")
    assert get_res.status_code == 404


def test_add_and_remove_pin_from_board(client, register):
    # Crear usuario y pin
    user_id, headers = register("david", "david@example.com")

    p_res = client.post(
        "/pins",
        json={
            "title": "Fotografía Nocturna",
            "category": "foto",
            "object_key": "originals/mock/night.jpg",
        },
        headers=headers,
    )
    pin_id = p_res.json()["id"]

    # Crear tablero
    b_res = client.post("/boards", json={"name": "Fotos Favoritas"}, headers=headers)
    board_id = b_res.json()["id"]

    # Agregar pin al tablero
    add_res = client.post(f"/boards/{board_id}/pins", json={"pin_id": pin_id}, headers=headers)
    assert add_res.status_code == 200
    assert "agregado al tablero" in add_res.json()["message"]

    # Consultar detalle del tablero
    det_res = client.get(f"/boards/{board_id}")
    assert det_res.status_code == 200
    det_data = det_res.json()
    assert len(det_data["pins"]) == 1
    assert det_data["pins"][0]["id"] == pin_id
    assert det_data["pins"][0]["title"] == "Fotografía Nocturna"

    # Listar tableros debe reportar pins_count == 1
    list_res = client.get(f"/boards?user_id={user_id}")
    assert list_res.json()[0]["pins_count"] == 1

    # Remover pin del tablero
    rem_res = client.delete(f"/boards/{board_id}/pins/{pin_id}", headers=headers)
    assert rem_res.status_code == 200

    # Consultar de nuevo: la lista de pines debe estar vacía
    det_res2 = client.get(f"/boards/{board_id}")
    assert det_res2.json()["pins"] == []


def test_board_error_cases(client, register):
    user_id, headers = register("eve", "eve@example.com")

    # Tablero inexistente
    assert client.get("/boards/missing-board").status_code == 404
    assert client.put("/boards/missing-board", json={"name": "x"}, headers=headers).status_code == 404
    assert client.delete("/boards/missing-board", headers=headers).status_code == 404

    # Crear tablero real
    b_res = client.post("/boards", json={"name": "Tablero Eve"}, headers=headers)
    board_id = b_res.json()["id"]

    # Agregar pin inexistente a tablero real -> 404
    res = client.post(f"/boards/{board_id}/pins", json={"pin_id": "missing-pin"}, headers=headers)
    assert res.status_code == 404

    # Agregar pin a tablero inexistente -> 404
    res = client.post("/boards/missing-board/pins", json={"pin_id": "pin-123"}, headers=headers)
    assert res.status_code == 404

    # Remover pin no asociado -> 404
    res = client.delete(f"/boards/{board_id}/pins/missing-pin", headers=headers)
    assert res.status_code == 404


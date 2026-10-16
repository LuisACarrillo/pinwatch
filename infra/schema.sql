-- Esquema relacional de PinWatch para PostgreSQL en Amazon RDS
-- Diseñado estrictamente con los campos requeridos por la aplicación actual.

CREATE TABLE IF NOT EXISTS users (
    id VARCHAR(36) PRIMARY KEY,
    username VARCHAR(50) NOT NULL UNIQUE,
    email VARCHAR(255) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS pins (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title VARCHAR(200) NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    category VARCHAR(80) NOT NULL,
    object_key VARCHAR(512) NOT NULL,
    likes_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL
);

-- Asegurar columna likes_count en entornos donde la tabla pins ya fue creada
ALTER TABLE pins ADD COLUMN IF NOT EXISTS likes_count INTEGER NOT NULL DEFAULT 0;

-- Flujo 2: resultado del procesamiento de la imagen (object_key es la llave en originals/).
-- status: pending al crear el pin, processed o rejected cuando termina la Lambda.
-- processed_key y thumbnail_key: llaves en el bucket pinwatch-processed-<cuenta>. La API las calcula
-- de object_key al crear el pin; los archivos existen cuando status es processed.
ALTER TABLE pins ADD COLUMN IF NOT EXISTS status VARCHAR(20) NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processed', 'rejected'));
ALTER TABLE pins ADD COLUMN IF NOT EXISTS processed_key VARCHAR(512);
ALTER TABLE pins ADD COLUMN IF NOT EXISTS thumbnail_key VARCHAR(512);

CREATE TABLE IF NOT EXISTS boards (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS board_pins (
    board_id VARCHAR(36) NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
    pin_id VARCHAR(36) NOT NULL REFERENCES pins(id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    PRIMARY KEY (board_id, pin_id)
);

CREATE TABLE IF NOT EXISTS notifications (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    pin_id VARCHAR(36) NOT NULL REFERENCES pins(id) ON DELETE CASCADE,
    message TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL
);

-- Índices de consulta frecuente para optimizar filtros y relaciones
CREATE INDEX IF NOT EXISTS idx_pins_category ON pins(category);
CREATE INDEX IF NOT EXISTS idx_pins_user_id ON pins(user_id);
CREATE INDEX IF NOT EXISTS idx_pins_object_key ON pins(object_key);
CREATE INDEX IF NOT EXISTS idx_boards_user_id ON boards(user_id);
CREATE INDEX IF NOT EXISTS idx_board_pins_pin_id ON board_pins(pin_id);
CREATE INDEX IF NOT EXISTS idx_notifications_user_id ON notifications(user_id);


.PHONY: up down status verify test help

help:
	@echo "Comandos disponibles en PinWatch:"
	@echo "  make up      - Despliega la infraestructura (S3, Secrets, SNS, EC2 bastión, RDS, Flujo 2) y levanta la API backend"
	@echo "  make down    - Da de baja los recursos de infraestructura en AWS (con confirmación)"
	@echo "  make status  - Consulta el estado de Secrets Manager, SNS, bastión EC2, RDS y Flujo 2"
	@echo "  make verify  - Comprueba el estado de la infraestructura de extremo a extremo"
	@echo "  make test    - Ejecuta las pruebas unitarias del backend"

up:
	bash start_backend.sh

down:
	bash infra/teardown.sh

status:
	bash infra/secrets.sh status
	bash infra/sns.sh status
	bash infra/ec2.sh status
	bash infra/rds.sh status
	bash infra/image_processor.sh status

verify:
	bash infra/verify.sh

test:
	pytest backend

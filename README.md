# Webhook em Haskell

Servidor HTTP simples para receber notificacoes de pagamento via webhook.

O projeto expoe a rota `POST /webhook` na porta `5000`, valida o token
`X-Webhook-Token`, verifica os campos obrigatorios do payload e evita confirmar
a mesma transacao duas vezes durante a execucao do servidor.

## Regras implementadas

- Token esperado: `meu-token-secreto`
- Payload esperado:

```json
{
  "event": "payment_success",
  "transaction_id": "abc123",
  "amount": "49.90",
  "currency": "BRL",
  "timestamp": "2023-10-01T12:00:00Z"
}
```

- Se a transacao for valida, retorna `200` e envia `POST /confirmar` para
  `http://127.0.0.1:5001`.
- Se faltar algum campo obrigatorio depois de `transaction_id`, se o valor/moeda
  estiver incorreto ou se a transacao for duplicada, retorna erro e envia
  `POST /cancelar` para `http://127.0.0.1:5001`.
- Se o token estiver incorreto, retorna erro e ignora a transacao.

## Itens opcionais implementados

1. Integridade do payload: o servidor valida se `event`, `amount`, `currency`,
   `timestamp` e `transaction_id` estao em formatos coerentes antes de aceitar a
   transacao.
2. Persistencia em BD local: transacoes confirmadas e canceladas sao gravadas em
   `transactions.db`, em formato JSON Lines.

## Como compilar

Requer GHC instalado.

```bash
ghc -Wall app/Main.hs -o webhook
```

## Como rodar

```bash
./webhook
```

O servidor ficara disponivel em:

```text
http://127.0.0.1:5000/webhook
```

## Como testar

Em outro terminal, instale as dependencias do teste fornecido pela disciplina.
Para manter tudo dentro do projeto, use:

```bash
python3 -m pip install --target .python-deps fastapi uvicorn requests
```

Depois execute:

```bash
PYTHONPATH=.python-deps python3 test_webhook.py
```

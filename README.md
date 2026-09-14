# SQL Commerce Analytics

Projeto técnico de portfólio em **SQL Server** que modela uma operação de vendas e estoque e demonstra recursos usados em cenários reais de dados.

## Competências demonstradas

- modelagem relacional normalizada e integridade referencial;
- constraints, índices filtrados e colunas calculadas;
- CTEs e funções de janela;
- views analíticas;
- stored procedures com transações e tratamento de erros;
- controle de concorrência no estoque;
- testes de integridade e regras de negócio.

## Estrutura

| Arquivo | Finalidade |
|---|---|
| `sql/01_schema.sql` | Schema, tabelas, constraints e índices |
| `sql/02_seed.sql` | Massa de dados reproduzível |
| `sql/03_analytics.sql` | Consultas avançadas e views |
| `sql/04_procedures.sql` | Procedures transacionais |
| `tests/01_data_quality_tests.sql` | Testes de integridade e qualidade |

## Domínio

O banco representa clientes, produtos, categorias, pedidos, itens, pagamentos e movimentações de estoque. O preço é preservado no item do pedido para garantir consistência histórica.

## Como executar

Requer SQL Server 2019+ ou Azure SQL Database.

1. Crie um banco vazio.
2. Execute os scripts na ordem numérica.
3. Execute os testes em `tests/`.
4. Consulte as views `analytics.vw_monthly_sales` e `analytics.vw_customer_rfm`.

> Dados e negócio são simulados exclusivamente para demonstração técnica.

## Decisões técnicas

- Valores monetários usam `decimal(19,4)`, evitando imprecisão de ponto flutuante.
- Datas são armazenadas em UTC com `datetime2`.
- Estoque é atualizado dentro de transação com locks de atualização para evitar venda acima do saldo.
- Pedidos usam status controlado por `CHECK`.
- Índices priorizam filtros comuns por cliente, período e status.

## Próximas evoluções

- pipeline ETL em Python;
- API REST em ASP.NET Core;
- execução automatizada dos testes em CI;
- dashboards de receita, retenção e giro de estoque.

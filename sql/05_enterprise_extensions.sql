SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF NOT EXISTS(SELECT 1 FROM sys.schemas WHERE name='platform') EXEC('CREATE SCHEMA platform');
IF NOT EXISTS(SELECT 1 FROM sys.schemas WHERE name='integration') EXEC('CREATE SCHEMA integration');
IF NOT EXISTS(SELECT 1 FROM sys.schemas WHERE name='audit') EXEC('CREATE SCHEMA audit');
GO

CREATE TABLE platform.tenant (
    tenant_id int IDENTITY(1,1) CONSTRAINT pk_tenant PRIMARY KEY,
    tenant_key uniqueidentifier NOT NULL CONSTRAINT df_tenant_key DEFAULT NEWSEQUENTIALID(),
    legal_name nvarchar(160) NOT NULL,
    plan_code varchar(20) NOT NULL,
    created_at datetime2(7) NOT NULL CONSTRAINT df_tenant_created DEFAULT SYSUTCDATETIME(),
    is_active bit NOT NULL CONSTRAINT df_tenant_active DEFAULT 1,
    CONSTRAINT uq_tenant_key UNIQUE(tenant_key),
    CONSTRAINT ck_tenant_plan CHECK(plan_code IN('STARTER','PRO','ENTERPRISE'))
);
GO

SET IDENTITY_INSERT platform.tenant ON;
INSERT platform.tenant(tenant_id,legal_name,plan_code) VALUES(1,N'Demo Commerce Ltda.','ENTERPRISE');
SET IDENTITY_INSERT platform.tenant OFF;
GO

ALTER TABLE sales.customer ADD tenant_id int NOT NULL
    CONSTRAINT df_customer_tenant DEFAULT(1),
    CONSTRAINT fk_customer_tenant FOREIGN KEY REFERENCES platform.tenant(tenant_id);
ALTER TABLE inventory.product ADD tenant_id int NOT NULL
    CONSTRAINT df_product_tenant DEFAULT(1),
    CONSTRAINT fk_product_tenant FOREIGN KEY REFERENCES platform.tenant(tenant_id);
ALTER TABLE sales.sales_order ADD tenant_id int NOT NULL
    CONSTRAINT df_order_tenant DEFAULT(1),
    CONSTRAINT fk_order_tenant FOREIGN KEY REFERENCES platform.tenant(tenant_id);
GO

CREATE INDEX ix_customer_tenant ON sales.customer(tenant_id,customer_id) INCLUDE(full_name,email,is_active);
CREATE INDEX ix_product_tenant_sku ON inventory.product(tenant_id,sku) INCLUDE(name,unit_price,stock_quantity);
CREATE INDEX ix_order_tenant_date ON sales.sales_order(tenant_id,order_date DESC) INCLUDE(customer_id,status,discount_amount);
GO

CREATE TABLE sales.order_status_history (
    history_id bigint IDENTITY(1,1) CONSTRAINT pk_order_status_history PRIMARY KEY,
    order_id bigint NOT NULL,
    from_status varchar(20) NULL,
    to_status varchar(20) NOT NULL,
    changed_at datetime2(7) NOT NULL CONSTRAINT df_status_changed DEFAULT SYSUTCDATETIME(),
    changed_by nvarchar(128) NOT NULL CONSTRAINT df_status_actor DEFAULT ORIGINAL_LOGIN(),
    correlation_id uniqueidentifier NOT NULL,
    reason nvarchar(300) NULL,
    CONSTRAINT fk_status_order FOREIGN KEY(order_id) REFERENCES sales.sales_order(order_id),
    CONSTRAINT ck_status_to CHECK(to_status IN('PENDING','PAID','SHIPPED','CANCELLED'))
);
CREATE INDEX ix_status_order_date ON sales.order_status_history(order_id,changed_at DESC);
GO

CREATE TABLE inventory.product_price_history (
    price_history_id bigint IDENTITY(1,1) CONSTRAINT pk_price_history PRIMARY KEY,
    product_id bigint NOT NULL,
    price decimal(19,4) NOT NULL,
    valid_from datetime2(7) GENERATED ALWAYS AS ROW START NOT NULL,
    valid_to datetime2(7) GENERATED ALWAYS AS ROW END NOT NULL,
    PERIOD FOR SYSTEM_TIME(valid_from,valid_to),
    CONSTRAINT fk_price_product FOREIGN KEY(product_id) REFERENCES inventory.product(product_id),
    CONSTRAINT ck_price_history CHECK(price>0)
) WITH (SYSTEM_VERSIONING=ON (
    HISTORY_TABLE=inventory.product_price_history_archive,
    DATA_CONSISTENCY_CHECK=ON
));
GO

CREATE TABLE integration.outbox_event (
    event_id uniqueidentifier NOT NULL CONSTRAINT df_outbox_id DEFAULT NEWSEQUENTIALID(),
    tenant_id int NOT NULL,
    aggregate_type varchar(60) NOT NULL,
    aggregate_id varchar(100) NOT NULL,
    event_type varchar(120) NOT NULL,
    payload nvarchar(max) NOT NULL,
    occurred_at datetime2(7) NOT NULL CONSTRAINT df_outbox_occurred DEFAULT SYSUTCDATETIME(),
    processed_at datetime2(7) NULL,
    retry_count int NOT NULL CONSTRAINT df_outbox_retry DEFAULT 0,
    last_error nvarchar(1000) NULL,
    CONSTRAINT pk_outbox PRIMARY KEY(event_id),
    CONSTRAINT fk_outbox_tenant FOREIGN KEY(tenant_id) REFERENCES platform.tenant(tenant_id),
    CONSTRAINT ck_outbox_json CHECK(ISJSON(payload)=1),
    CONSTRAINT ck_outbox_retry CHECK(retry_count>=0)
);
CREATE INDEX ix_outbox_pending ON integration.outbox_event(occurred_at,event_id)
INCLUDE(tenant_id,event_type,retry_count) WHERE processed_at IS NULL;
GO

CREATE TABLE integration.idempotency_key (
    tenant_id int NOT NULL,
    idempotency_key uniqueidentifier NOT NULL,
    operation varchar(80) NOT NULL,
    resource_id varchar(100) NULL,
    request_hash binary(32) NOT NULL,
    created_at datetime2(7) NOT NULL CONSTRAINT df_idempotency_created DEFAULT SYSUTCDATETIME(),
    expires_at datetime2(7) NOT NULL,
    CONSTRAINT pk_idempotency PRIMARY KEY(tenant_id,idempotency_key),
    CONSTRAINT fk_idempotency_tenant FOREIGN KEY(tenant_id) REFERENCES platform.tenant(tenant_id),
    CONSTRAINT ck_idempotency_expiry CHECK(expires_at>created_at)
);
GO

CREATE TABLE audit.change_event (
    audit_id bigint IDENTITY(1,1) CONSTRAINT pk_change_event PRIMARY KEY,
    tenant_id int NULL,
    entity_name sysname NOT NULL,
    entity_id varchar(100) NOT NULL,
    action_type varchar(10) NOT NULL,
    changed_at datetime2(7) NOT NULL CONSTRAINT df_audit_changed DEFAULT SYSUTCDATETIME(),
    changed_by nvarchar(128) NOT NULL,
    correlation_id uniqueidentifier NULL,
    before_json nvarchar(max) NULL,
    after_json nvarchar(max) NULL,
    CONSTRAINT ck_audit_action CHECK(action_type IN('INSERT','UPDATE','DELETE')),
    CONSTRAINT ck_audit_before_json CHECK(before_json IS NULL OR ISJSON(before_json)=1),
    CONSTRAINT ck_audit_after_json CHECK(after_json IS NULL OR ISJSON(after_json)=1)
);
CREATE INDEX ix_audit_entity ON audit.change_event(entity_name,entity_id,changed_at DESC);
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'sales') EXEC('CREATE SCHEMA sales');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'inventory') EXEC('CREATE SCHEMA inventory');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'analytics') EXEC('CREATE SCHEMA analytics');
GO

CREATE TABLE sales.customer (
    customer_id bigint IDENTITY(1,1) CONSTRAINT pk_customer PRIMARY KEY,
    full_name nvarchar(150) NOT NULL,
    email varchar(254) NOT NULL,
    document_number varchar(20) NULL,
    created_at datetime2(0) NOT NULL CONSTRAINT df_customer_created DEFAULT SYSUTCDATETIME(),
    is_active bit NOT NULL CONSTRAINT df_customer_active DEFAULT 1,
    CONSTRAINT uq_customer_email UNIQUE (email)
);
GO

CREATE TABLE inventory.category (
    category_id int IDENTITY(1,1) CONSTRAINT pk_category PRIMARY KEY,
    name nvarchar(100) NOT NULL CONSTRAINT uq_category_name UNIQUE
);
GO

CREATE TABLE inventory.product (
    product_id bigint IDENTITY(1,1) CONSTRAINT pk_product PRIMARY KEY,
    category_id int NOT NULL,
    sku varchar(40) NOT NULL,
    name nvarchar(160) NOT NULL,
    unit_price decimal(19,4) NOT NULL,
    stock_quantity int NOT NULL CONSTRAINT df_product_stock DEFAULT 0,
    reorder_level int NOT NULL CONSTRAINT df_product_reorder DEFAULT 5,
    row_version rowversion NOT NULL,
    CONSTRAINT fk_product_category FOREIGN KEY (category_id) REFERENCES inventory.category(category_id),
    CONSTRAINT uq_product_sku UNIQUE (sku),
    CONSTRAINT ck_product_price CHECK (unit_price > 0),
    CONSTRAINT ck_product_stock CHECK (stock_quantity >= 0),
    CONSTRAINT ck_product_reorder CHECK (reorder_level >= 0)
);
GO

CREATE TABLE sales.sales_order (
    order_id bigint IDENTITY(1,1) CONSTRAINT pk_sales_order PRIMARY KEY,
    customer_id bigint NOT NULL,
    order_date datetime2(0) NOT NULL CONSTRAINT df_order_date DEFAULT SYSUTCDATETIME(),
    status varchar(20) NOT NULL CONSTRAINT df_order_status DEFAULT 'PENDING',
    discount_amount decimal(19,4) NOT NULL CONSTRAINT df_order_discount DEFAULT 0,
    notes nvarchar(500) NULL,
    CONSTRAINT fk_order_customer FOREIGN KEY (customer_id) REFERENCES sales.customer(customer_id),
    CONSTRAINT ck_order_status CHECK (status IN ('PENDING','PAID','SHIPPED','CANCELLED')),
    CONSTRAINT ck_order_discount CHECK (discount_amount >= 0)
);
GO

CREATE TABLE sales.order_item (
    order_item_id bigint IDENTITY(1,1) CONSTRAINT pk_order_item PRIMARY KEY,
    order_id bigint NOT NULL,
    product_id bigint NOT NULL,
    quantity int NOT NULL,
    unit_price decimal(19,4) NOT NULL,
    line_total AS CONVERT(decimal(19,4), quantity * unit_price) PERSISTED,
    CONSTRAINT fk_item_order FOREIGN KEY (order_id) REFERENCES sales.sales_order(order_id),
    CONSTRAINT fk_item_product FOREIGN KEY (product_id) REFERENCES inventory.product(product_id),
    CONSTRAINT uq_item_order_product UNIQUE (order_id, product_id),
    CONSTRAINT ck_item_quantity CHECK (quantity > 0),
    CONSTRAINT ck_item_price CHECK (unit_price > 0)
);
GO

CREATE TABLE sales.payment (
    payment_id bigint IDENTITY(1,1) CONSTRAINT pk_payment PRIMARY KEY,
    order_id bigint NOT NULL,
    paid_at datetime2(0) NOT NULL CONSTRAINT df_payment_date DEFAULT SYSUTCDATETIME(),
    amount decimal(19,4) NOT NULL,
    method varchar(20) NOT NULL,
    external_reference varchar(100) NULL,
    CONSTRAINT fk_payment_order FOREIGN KEY (order_id) REFERENCES sales.sales_order(order_id),
    CONSTRAINT ck_payment_amount CHECK (amount > 0),
    CONSTRAINT ck_payment_method CHECK (method IN ('PIX','CARD','BOLETO','TRANSFER'))
);
GO

CREATE TABLE inventory.stock_movement (
    movement_id bigint IDENTITY(1,1) CONSTRAINT pk_stock_movement PRIMARY KEY,
    product_id bigint NOT NULL,
    order_id bigint NULL,
    movement_type varchar(10) NOT NULL,
    quantity int NOT NULL,
    occurred_at datetime2(0) NOT NULL CONSTRAINT df_movement_date DEFAULT SYSUTCDATETIME(),
    reason nvarchar(200) NULL,
    CONSTRAINT fk_movement_product FOREIGN KEY (product_id) REFERENCES inventory.product(product_id),
    CONSTRAINT fk_movement_order FOREIGN KEY (order_id) REFERENCES sales.sales_order(order_id),
    CONSTRAINT ck_movement_type CHECK (movement_type IN ('IN','OUT')),
    CONSTRAINT ck_movement_quantity CHECK (quantity > 0)
);
GO

CREATE INDEX ix_order_customer_date ON sales.sales_order(customer_id, order_date DESC) INCLUDE(status, discount_amount);
CREATE INDEX ix_order_status_date ON sales.sales_order(status, order_date DESC);
CREATE INDEX ix_item_product ON sales.order_item(product_id) INCLUDE(quantity, unit_price);
CREATE INDEX ix_payment_order ON sales.payment(order_id) INCLUDE(amount, paid_at);
CREATE INDEX ix_product_reorder ON inventory.product(stock_quantity, reorder_level) INCLUDE(sku, name)
WHERE stock_quantity <= reorder_level;
GO

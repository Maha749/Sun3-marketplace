-- صُنع: مخطط قاعدة البيانات الأولي لـ Supabase
-- نفّذي هذا الملف في SQL Editor بعد مراجعة سياسات الأمان قبل الإطلاق.

create type public.account_role as enum ('customer','seller','admin');
create type public.product_status as enum ('pending','approved','rejected','hidden');
create type public.order_status as enum ('new','accepted','preparing','shipped','completed','cancelled');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  role public.account_role not null default 'customer',
  shop_name text,
  phone text,
  city text,
  created_at timestamptz not null default now()
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references public.profiles(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 120),
  category text not null,
  description text not null default '',
  price numeric(10,2) not null check (price > 0),
  image_url text,
  status public.product_status not null default 'pending',
  created_at timestamptz not null default now()
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.profiles(id),
  total_amount numeric(10,2) not null default 0 check (total_amount >= 0),
  status public.order_status not null default 'new',
  delivery_name text,
  delivery_phone text,
  delivery_address text,
  created_at timestamptz not null default now()
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid not null references public.products(id),
  seller_id uuid not null references public.profiles(id),
  quantity integer not null default 1 check (quantity > 0),
  unit_price numeric(10,2) not null check (unit_price > 0),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

-- المستخدم يرى ملفه، والإدارة فقط تعدّل الأدوار يدويًا من لوحة آمنة.
create policy "profiles read self" on public.profiles for select to authenticated using (id = auth.uid());
create policy "profiles insert self customer or seller" on public.profiles for insert to authenticated with check (id = auth.uid() and role in ('customer','seller'));
create policy "profiles update self" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid() and role in ('customer','seller'));

-- الزوار يرون المنتجات المعتمدة فقط. البائع يدير منتجاته، وكل منتج جديد ينتظر المراجعة.
create policy "public read approved products" on public.products for select using (status = 'approved' or seller_id = auth.uid());
create policy "seller insert own pending products" on public.products for insert to authenticated with check (seller_id = auth.uid() and status = 'pending');
create policy "seller update own products" on public.products for update to authenticated using (seller_id = auth.uid()) with check (seller_id = auth.uid() and status in ('pending','hidden'));
create policy "seller delete own pending products" on public.products for delete to authenticated using (seller_id = auth.uid() and status = 'pending');

-- العميل يرى طلباته. البائع يرى الطلبات التي تحتوي على منتجاته عبر عناصر الطلب.
create policy "customer read own orders" on public.orders for select to authenticated using (customer_id = auth.uid());
create policy "customer create own order" on public.orders for insert to authenticated with check (customer_id = auth.uid() and status = 'new');
create policy "seller read own order items" on public.order_items for select to authenticated using (seller_id = auth.uid() or exists (select 1 from public.orders o where o.id = order_id and o.customer_id = auth.uid()));
create policy "customer insert own order items" on public.order_items for insert to authenticated with check (
  exists (select 1 from public.orders o where o.id = order_id and o.customer_id = auth.uid())
  and exists (select 1 from public.products p where p.id = product_id and p.status = 'approved' and p.seller_id = seller_id)
);

-- تنبيه: الإنتاج يتطلب إنشاء الطلب وعناصره داخل RPC/دالة قاعدة بيانات transaction-safe
-- مع حساب الإجمالي من أسعار قاعدة البيانات، وإضافة سياسات تحديث حالة الطلب للبائع والإدارة.

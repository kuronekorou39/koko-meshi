-- =============================================
-- ココメシ Supabase テーブル定義
-- Supabase Dashboard > SQL Editor で実行してください
-- =============================================

-- 1. プロフィールテーブル（auth.usersと1:1）
CREATE TABLE IF NOT EXISTS profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name TEXT NOT NULL DEFAULT '',
  email TEXT,
  avatar_url TEXT,
  plan TEXT NOT NULL DEFAULT 'free',  -- free / premium
  storage_used_bytes BIGINT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- RLS 有効化
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- 自分のプロフィールのみ読み書き可能
CREATE POLICY "Users can view own profile"
  ON profiles FOR SELECT USING (auth.uid() = id);
CREATE POLICY "Users can update own profile"
  ON profiles FOR UPDATE USING (auth.uid() = id);
CREATE POLICY "Users can insert own profile"
  ON profiles FOR INSERT WITH CHECK (auth.uid() = id);


-- 2. 食事記録テーブル
CREATE TABLE IF NOT EXISTS meal_logs (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  meal_type TEXT NOT NULL,
  restaurant_id UUID,
  eaten_at TIMESTAMPTZ NOT NULL,
  total_price INTEGER,
  note TEXT,
  location_tag TEXT,
  latitude DOUBLE PRECISION,
  longitude DOUBLE PRECISION,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE meal_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can manage own meal_logs"
  ON meal_logs FOR ALL USING (auth.uid() = user_id);


-- 3. 食事写真テーブル
CREATE TABLE IF NOT EXISTS meal_photos (
  id UUID PRIMARY KEY,
  meal_log_id UUID NOT NULL REFERENCES meal_logs(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  original_url TEXT,
  thumbnail_url TEXT,
  ai_status TEXT NOT NULL DEFAULT 'pending',
  ai_menu_name TEXT,
  ai_estimated_price INTEGER,
  ai_estimated_calories INTEGER,
  ai_cuisine_genre TEXT,
  ai_model TEXT,
  user_corrected_name TEXT,
  user_corrected_price INTEGER,
  user_corrected_calories INTEGER,
  shot_at TIMESTAMPTZ NOT NULL,
  latitude DOUBLE PRECISION,
  longitude DOUBLE PRECISION,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE meal_photos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can manage own meal_photos"
  ON meal_photos FOR ALL USING (auth.uid() = user_id);


-- 4. レストランテーブル（共有データ）
CREATE TABLE IF NOT EXISTS restaurants (
  id UUID PRIMARY KEY,
  google_place_id TEXT UNIQUE,
  name TEXT NOT NULL,
  address TEXT,
  latitude DOUBLE PRECISION,
  longitude DOUBLE PRECISION,
  cuisine_genre TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE restaurants ENABLE ROW LEVEL SECURITY;

-- 全ユーザーが読み取り可能、認証済みユーザーが追加可能
CREATE POLICY "Anyone can read restaurants"
  ON restaurants FOR SELECT USING (true);
CREATE POLICY "Authenticated users can insert restaurants"
  ON restaurants FOR INSERT WITH CHECK (auth.role() = 'authenticated');


-- 5. 保存場所テーブル
CREATE TABLE IF NOT EXISTS saved_places (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  latitude DOUBLE PRECISION NOT NULL,
  longitude DOUBLE PRECISION NOT NULL,
  icon_type TEXT NOT NULL DEFAULT 'custom',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE saved_places ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can manage own saved_places"
  ON saved_places FOR ALL USING (auth.uid() = user_id);


-- 6. プラン定数
-- free: ストレージ 500MB
-- premium: ストレージ 50GB

-- 7. 新規ユーザー作成時に自動でprofilesレコードを作成するトリガー
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO profiles (id, display_name, email)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'display_name', split_part(NEW.email, '@', 1)),
    NEW.email
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();


-- =============================================
-- 8. Storage バケット作成 (SQL Editor で実行)
-- =============================================
INSERT INTO storage.buckets (id, name, public)
VALUES ('meal-photos', 'meal-photos', true)
ON CONFLICT (id) DO NOTHING;

-- 認証済みユーザーのみアップロード可能（自分のフォルダのみ）
CREATE POLICY "Users can upload own photos"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'meal-photos'
    AND auth.role() = 'authenticated'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- 自分の写真の読み取り
CREATE POLICY "Users can read own photos"
  ON storage.objects FOR SELECT
  USING (
    bucket_id = 'meal-photos'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- 公開バケットなので全員読み取り可能（URLを知っていれば）
CREATE POLICY "Public read access"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'meal-photos');

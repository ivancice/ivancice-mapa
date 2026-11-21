-- =====================================================================
-- Úložiště fotografií (Supabase Storage)
-- Bucket „photos“: veřejné čtení (náhodné UUID cesty), zápis jen do vlastní
-- složky přihlášeného uživatele, max. 6 MB, pouze obrázky.
-- Skrytí fotografie moderátorem ji odstraní z aplikace; trvalé smazání
-- souboru provádí administrace (Storage API s právy administrátora).
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 6291456, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "photos_insert_own_folder" on storage.objects;
create policy "photos_insert_own_folder" on storage.objects for insert to authenticated
  with check (
    bucket_id = 'photos'
    and (storage.foldername(name))[1] = auth.uid()::text
    and not exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_blocked)
  );

drop policy if exists "photos_read" on storage.objects;
create policy "photos_read" on storage.objects for select to anon, authenticated
  using (bucket_id = 'photos');

drop policy if exists "photos_delete_own_or_admin" on storage.objects;
create policy "photos_delete_own_or_admin" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

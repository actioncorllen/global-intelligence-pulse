-- Regenerate dr/manifests/storage_manifest.json (reconciliation manifest; NO bytes, NO secrets).
-- Run with: psql "$SUPABASE_DB_URL" -Atqf scripts/dr/dr_storage_manifest.sql > dr/manifests/storage_manifest.json
SELECT jsonb_pretty(jsonb_build_object(
  'object_count', (SELECT count(*) FROM storage.objects),
  'buckets', (SELECT jsonb_agg(jsonb_build_object('bucket',id,'public',public)) FROM storage.buckets),
  'objects', coalesce((SELECT jsonb_agg(jsonb_build_object(
      'bucket',bucket_id,'path',name,'size',(metadata->>'size')::bigint,
      'mime',metadata->>'mimetype','etag',metadata->>'eTag',
      'created',created_at,'updated',updated_at) ORDER BY name) FROM storage.objects),'[]'::jsonb)
));

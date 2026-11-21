'use client';
import { getSupabase } from '@/lib/supabase/client';

export interface UploadedPhoto {
  path: string;
  width: number;
  height: number;
}

const MAX_SIDE = 1600;

/** Zmenší fotografii v prohlížeči (rychlejší nahrání z mobilu, odstraní EXIF vč. GPS). */
export async function resizeImage(file: File): Promise<{ blob: Blob; width: number; height: number }> {
  const bitmap = await loadBitmap(file);
  const scale = Math.min(1, MAX_SIDE / Math.max(bitmap.width, bitmap.height));
  const width = Math.round(bitmap.width * scale);
  const height = Math.round(bitmap.height * scale);
  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error('Prohlížeč nepodporuje zpracování obrázků.');
  ctx.drawImage(bitmap as CanvasImageSource, 0, 0, width, height);
  if ('close' in bitmap && typeof bitmap.close === 'function') bitmap.close();
  const blob: Blob = await new Promise((resolve, reject) =>
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('Fotografii se nepodařilo zpracovat.'))), 'image/jpeg', 0.82)
  );
  return { blob, width, height };
}

async function loadBitmap(file: File): Promise<ImageBitmap | HTMLImageElement> {
  if (typeof createImageBitmap === 'function') {
    try {
      return await createImageBitmap(file, { imageOrientation: 'from-image' } as ImageBitmapOptions);
    } catch {
      /* fallback */
    }
  }
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error('Soubor není podporovaný obrázek.'));
    img.src = URL.createObjectURL(file);
  });
}

export async function uploadPhoto(file: File, userId: string): Promise<UploadedPhoto> {
  if (!file.type.startsWith('image/')) throw new Error('Vyberte prosím obrázek (JPG, PNG, HEIC…).');
  if (file.size > 25 * 1024 * 1024) throw new Error('Fotografie je příliš velká (max. 25 MB).');
  const { blob, width, height } = await resizeImage(file);
  const name = `${crypto.randomUUID()}.jpg`;
  const path = `${userId}/${name}`;
  const { error } = await getSupabase().storage.from('photos').upload(path, blob, {
    contentType: 'image/jpeg',
    cacheControl: '31536000',
    upsert: false
  });
  if (error) throw new Error('Nahrání fotografie selhalo: ' + error.message);
  return { path, width, height };
}

export async function deleteStoragePhotos(paths: string[]) {
  if (!paths.length) return;
  await getSupabase().storage.from('photos').remove(paths);
}

import AsyncStorage from '@react-native-async-storage/async-storage';
import type {Observation} from './types';
import {DEMO_OBSERVATIONS} from './data/seedData';

const KEY = 'guanzhi.observations';
const SEEDED_KEY = 'guanzhi.seeded.v2';

export async function loadObservations(): Promise<Observation[]> {
  const seeded = await AsyncStorage.getItem(SEEDED_KEY);
  if (!seeded) {
    await AsyncStorage.setItem(KEY, JSON.stringify(DEMO_OBSERVATIONS));
    await AsyncStorage.setItem(SEEDED_KEY, '1');
    return DEMO_OBSERVATIONS;
  }
  const raw = await AsyncStorage.getItem(KEY);
  if (!raw) return [];
  try {
    return JSON.parse(raw) as Observation[];
  } catch {
    return [];
  }
}

export async function saveObservations(list: Observation[]) {
  await AsyncStorage.setItem(KEY, JSON.stringify(list));
}

// 万象书屋: 读-改-写串行队列. 之前 add/delete/update 各自 loadObservations() → 内存改 →
// saveObservations(), 快速连点会读到同一份旧列表, 后写覆盖先写导致丢数据.
let writeQueue: Promise<unknown> = Promise.resolve();

function enqueueWrite<T>(fn: () => Promise<T>): Promise<T> {
  const result = writeQueue.then(fn);
  writeQueue = result.catch(() => {});
  return result;
}

export function addObservation(item: Observation): Promise<void> {
  return enqueueWrite(async () => {
    const list = await loadObservations();
    list.unshift(item);
    await saveObservations(list);
  });
}

export function deleteObservation(id: string): Promise<void> {
  return enqueueWrite(async () => {
    const list = await loadObservations();
    await saveObservations(list.filter(o => o.id !== id));
  });
}

export function updateObservation(id: string, patch: Partial<Observation>): Promise<void> {
  return enqueueWrite(async () => {
    const list = await loadObservations();
    const idx = list.findIndex(o => o.id === id);
    if (idx < 0) return;
    list[idx] = {...list[idx], ...patch};
    await saveObservations(list);
  });
}

export function observationsByPlantName(list: Observation[], plantName: string) {
  return list.filter(o => o.plantName === plantName).sort((a, b) => b.date.localeCompare(a.date));
}

export function groupObservationsByMonth(list: Observation[]) {
  const map = new Map<string, Observation[]>();
  list.forEach(o => {
    const ym = o.date.slice(0, 7);
    const bucket = map.get(ym) || [];
    bucket.push(o);
    map.set(ym, bucket);
  });
  return Array.from(map.entries())
    .sort((a, b) => b[0].localeCompare(a[0]))
    .map(([ym, items]) => ({ym, items: items.sort((a, b) => b.date.localeCompare(a.date))}));
}

const ONBOARDING_KEY = 'guanzhi.onboarding.done';

export async function isOnboardingDone(): Promise<boolean> {
  return (await AsyncStorage.getItem(ONBOARDING_KEY)) === '1';
}

export async function setOnboardingDone() {
  await AsyncStorage.setItem(ONBOARDING_KEY, '1');
}

export function uniquePlantCount(list: Observation[]) {
  return new Set(list.map(o => o.plantName)).size;
}

export function thisMonthCount(list: Observation[]) {
  const now = new Date();
  const ym = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
  return list.filter(o => o.date.startsWith(ym)).length;
}

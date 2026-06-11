export type Season = '春季' | '夏季' | '秋季' | '冬季';
export type Habitat = '公园' | '阳台' | '野外' | '校园' | '路边';

export interface ReferencePlant {
  id: string;
  name: string;
  latin: string;
  family: string;
  bloom: string;
  habitat: Habitat[];
  traits: string[];
  note: string;
  imageAsset: string;
}

export interface Observation {
  id: string;
  plantName: string;
  referenceId?: string;
  location: string;
  habitat: Habitat;
  season: Season;
  note: string;
  date: string;
  imageUri?: string;
  imageAsset?: string;
}

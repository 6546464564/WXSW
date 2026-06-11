export const PLANT_IMAGES: Record<string, number> = {
  ginkgo: require('./images/ginkgo.jpg'),
  osmanthus: require('./images/osmanthus.jpg'),
  succulent: require('./images/succulent.jpg'),
  clover: require('./images/clover.jpg'),
  fern: require('./images/fern.jpg'),
  bamboo: require('./images/bamboo.jpg'),
  mint: require('./images/mint.jpg'),
  camellia: require('./images/camellia.jpg'),
  wisteria: require('./images/wisteria.jpg'),
  dandelion: require('./images/dandelion.jpg'),
  aloe: require('./images/aloe.jpg'),
  pothos: require('./images/pothos.jpg'),
};

export function resolveImageSource(item: {imageUri?: string; imageAsset?: string}) {
  if (item.imageUri) return {uri: item.imageUri};
  if (item.imageAsset && PLANT_IMAGES[item.imageAsset]) {
    return PLANT_IMAGES[item.imageAsset];
  }
  return null;
}

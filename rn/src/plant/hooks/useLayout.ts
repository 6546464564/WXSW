import {useWindowDimensions} from 'react-native';

export function useLayout() {
  const {width} = useWindowDimensions();
  const isTablet = width >= 768;
  const isWide = width >= 600;
  const columns = isTablet ? 3 : isWide ? 2 : 1;
  const padX = isTablet ? 40 : isWide ? 28 : 20;
  return {width, isTablet, isWide, columns, padX};
}

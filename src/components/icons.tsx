import Svg, { Circle, Path, Rect } from 'react-native-svg';

interface IconProps {
  size?: number;
  color?: string;
  strokeWidth?: number;
}

export function SearchIcon({ size = 14, color = 'rgba(255,255,255,.5)', strokeWidth = 1.6 }: IconProps) {
  return (
    <Svg width={size} height={size} viewBox="0 0 16 16" fill="none">
      <Circle cx={7} cy={7} r={5} stroke={color} strokeWidth={strokeWidth} />
      <Path d="M10.8 10.8L14 14" stroke={color} strokeWidth={strokeWidth} />
    </Svg>
  );
}

export function ChevronDownIcon({ size = 11, color = 'rgba(255,255,255,.45)', strokeWidth = 1.6 }: IconProps) {
  return (
    <Svg width={size} height={size} viewBox="0 0 12 12" fill="none">
      <Path d="M3 4.5L6 7.5l3-3" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" />
    </Svg>
  );
}

export function ChevronRightIcon({ size = 12, color = 'rgba(255,255,255,.35)', strokeWidth = 1.7 }: IconProps) {
  return (
    <Svg width={size} height={size} viewBox="0 0 12 12" fill="none">
      <Path d="M4.5 3l3 3-3 3" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" />
    </Svg>
  );
}

export function PlusIcon({ size = 16, color = '#fff', strokeWidth = 2 }: IconProps) {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <Path d="M12 5v14M5 12h14" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" />
    </Svg>
  );
}

export function PinIcon({ size = 18, color = '#fff', strokeWidth = 1.7 }: IconProps) {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <Path
        d="M12 20s7-5.2 7-11a7 7 0 1 0-14 0c0 5.8 7 11 7 11z"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <Circle cx={12} cy={9} r={2.4} stroke={color} strokeWidth={strokeWidth} />
    </Svg>
  );
}

export function MessageIcon({ size = 18, color = '#fff', strokeWidth = 1.7 }: IconProps) {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <Path
        d="M4 6.5h16v11H8.5L4 20.5z"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </Svg>
  );
}

export function SettingsIcon({ size = 15, color = '#fff', strokeWidth = 1.7 }: IconProps) {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <Circle cx={12} cy={12} r={3.2} stroke={color} strokeWidth={strokeWidth} />
      <Path
        d="M12 3.5v2.2M12 18.3v2.2M4.9 7.8l1.9 1.1M17.2 15.1l1.9 1.1M4.9 16.2l1.9-1.1M17.2 8.9l1.9-1.1"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
      />
    </Svg>
  );
}

export function TabMapIcon({ size = 22, color = '#fff', strokeWidth = 1.7 }: IconProps) {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <Path
        d="M9 3.5 3.5 5.5v15L9 18.5l6 2 5.5-2v-15L15 5.5z"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <Path d="M9 3.5v15M15 5.5v15" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round" />
    </Svg>
  );
}

export function TabGarageIcon({ size = 22, color = '#fff', strokeWidth = 1.7 }: IconProps) {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <Path
        d="M3.5 10 12 4.5l8.5 5.5v10h-17z"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <Path d="M7.5 20v-6h9v6" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round" />
    </Svg>
  );
}

export function TabMeetsIcon({ size = 22, color = '#fff', strokeWidth = 1.7 }: IconProps) {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <Rect x={3.5} y={5.5} width={17} height={15} rx={3} stroke={color} strokeWidth={strokeWidth} />
      <Path d="M8 3.5v3M16 3.5v3M3.5 10.5h17" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" />
      <Circle cx={12} cy={15.2} r={1.5} fill={color} stroke="none" />
    </Svg>
  );
}

export function TabActivityIcon({ size = 22, color = '#fff', strokeWidth = 1.7 }: IconProps) {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <Path
        d="M6 10a6 6 0 1 1 12 0c0 4 1.5 5.5 1.5 5.5h-15S6 14 6 10z"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <Path d="M10 18.5a2.2 2.2 0 0 0 4 0" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" />
    </Svg>
  );
}

export function CoupeSilhouette({ width = 48, height = 20, color = 'rgba(255,255,255,.95)', strokeWidth = 1.5 }: { width?: number; height?: number; color?: string; strokeWidth?: number }) {
  return (
    <Svg width={width} height={height} viewBox="0 0 48 20" fill="none">
      <Path
        d="M3.5 15c0-1.3.6-2 1.8-2.3l8.4-1.8 3.6-2.7c1.9-1.5 3.7-2.1 6.3-2.1h4.6c3 0 5.2.8 7.2 2.4l4.2 3.3 2.3.6c1.2.3 1.7 1 1.7 2.3"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <Path d="M3.5 15h6.2M16.9 15h14.7M38.6 15h5.6" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round" />
      <Circle cx={13.3} cy={15} r={3.4} stroke={color} strokeWidth={strokeWidth} />
      <Circle cx={35.1} cy={15} r={3.4} stroke={color} strokeWidth={strokeWidth} />
    </Svg>
  );
}

export function SportbikeSilhouette({ width = 44, height = 20, color = 'rgba(255,255,255,.92)', strokeWidth = 1.5 }: { width?: number; height?: number; color?: string; strokeWidth?: number }) {
  return (
    <Svg width={width} height={height} viewBox="0 0 44 20" fill="none">
      <Circle cx={9.6} cy={13.6} r={4.4} stroke={color} strokeWidth={strokeWidth} />
      <Circle cx={34.4} cy={13.6} r={4.4} stroke={color} strokeWidth={strokeWidth} />
      <Path
        d="M9.6 13.6l4.8-4.4 6.4-1.4h4.6l3.6 1.6 5.4 4.2"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <Path d="M19.4 7.4l3.6-2.6" stroke={color} strokeWidth={1.3} strokeLinecap="round" />
      <Path d="M27.4 9l3.6-2.4" stroke={color} strokeWidth={1.3} strokeLinecap="round" />
    </Svg>
  );
}

export function SedanSilhouette({ width = 44, height = 19, color = 'rgba(255,255,255,.8)', strokeWidth = 1.5 }: { width?: number; height?: number; color?: string; strokeWidth?: number }) {
  return (
    <Svg width={width} height={height} viewBox="0 0 48 20" fill="none">
      <Path
        d="M3.5 15c0-1.3.6-2 1.8-2.3l8-1.6 3.2-3.2c1.8-1.7 3.6-2.3 6.2-2.3h5c3 0 5 .8 7 2.4l4.2 3.4 2.3.6c1.2.3 1.7 1 1.7 2.3"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <Path d="M3.5 15h6.2M16.9 15h14.7M38.6 15h5.6" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round" />
      <Circle cx={13.3} cy={15} r={3.4} stroke={color} strokeWidth={strokeWidth} />
      <Circle cx={35.1} cy={15} r={3.4} stroke={color} strokeWidth={strokeWidth} />
    </Svg>
  );
}

export function CruiseArrowIcon({ size = 9, color = '#fff', strokeWidth = 1.7 }: IconProps) {
  return (
    <Svg width={size} height={size} viewBox="0 0 12 12" fill="none">
      <Path d="M2 6h6M6 3l3 3-3 3" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" />
    </Svg>
  );
}

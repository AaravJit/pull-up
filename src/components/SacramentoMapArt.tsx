import Svg, { Defs, G, Path, Pattern, RadialGradient, Rect, Stop, Text } from 'react-native-svg';

/**
 * Stylized nighttime Sacramento map art — a decorative vector backdrop
 * (block grid, river, bridge, streets, neighborhood labels), not a real
 * mapping layer. Recreated 1:1 from the design's inline SVG.
 */
export function SacramentoMapArt() {
  return (
    <Svg viewBox="0 0 522 994" width="100%" height="100%" preserveAspectRatio="xMidYMid slice">
      <Defs>
        <Pattern id="pu-blocks" width={54} height={62} patternUnits="userSpaceOnUse">
          <Rect x={3.5} y={3.5} width={47} height={55} rx={2.5} fill="#101216" />
        </Pattern>
        <Pattern id="pu-blocks-fine" width={34} height={40} patternUnits="userSpaceOnUse">
          <Rect x={2.5} y={2.5} width={29} height={35} rx={2} fill="#101216" />
        </Pattern>
        <RadialGradient id="pu-vignette" cx="50%" cy="42%" r="72%">
          <Stop offset="55%" stopColor="#000" stopOpacity={0} />
          <Stop offset="100%" stopColor="#000" stopOpacity={0.55} />
        </RadialGradient>
      </Defs>

      <Rect width={522} height={994} fill="#191c21" />

      <G transform="rotate(-7 261 497)">
        <Rect x={-90} y={-80} width={720} height={1160} fill="url(#pu-blocks)" />
        <Rect x={-90} y={620} width={720} height={460} fill="url(#pu-blocks-fine)" />
      </G>

      <Path
        d="M-20 -40 C 60 140, 20 300, 96 470 C 150 590, 120 740, 176 1030 L 60 1030 C 20 760, 30 600, -30 420 Z"
        fill="#0a1017"
      />
      <Path
        d="M-20 -40 C 60 140, 20 300, 96 470 C 150 590, 120 740, 176 1030"
        fill="none"
        stroke="#1c2530"
        strokeWidth={1.2}
      />
      <Path
        d="M522 118 C 420 150, 330 210, 246 262 C 190 296, 150 330, 96 402"
        fill="none"
        stroke="#0a1017"
        strokeWidth={26}
      />
      <Path
        d="M60 96 C 150 250, 190 420, 230 620 C 258 760, 300 880, 360 1010"
        fill="none"
        stroke="#23272e"
        strokeWidth={9}
      />
      <Path
        d="M60 96 C 150 250, 190 420, 230 620 C 258 760, 300 880, 360 1010"
        fill="none"
        stroke="#2c313a"
        strokeWidth={1}
        strokeDasharray="14 12"
      />
      <Path d="M-30 742 C 120 706, 300 686, 546 660" fill="none" stroke="#23272e" strokeWidth={8} />
      <Path d="M120 420 L 470 380" fill="none" stroke="#20242a" strokeWidth={4} />
      <Path d="M170 250 L 520 206" fill="none" stroke="#20242a" strokeWidth={3.5} />

      <Rect x={266} y={446} width={118} height={86} rx={4} fill="#121611" transform="rotate(-7 261 497)" />

      <Rect width={522} height={994} fill="url(#pu-vignette)" />

      <G fill="#5d636d" fontFamily="Inter" fontSize={9.5} letterSpacing={1.6} fontWeight="500">
        <Text x={150} y={300} transform="rotate(-7 150 300)">
          OLD SAC
        </Text>
        <Text x={330} y={392} transform="rotate(-7 330 392)">
          MIDTOWN
        </Text>
        <Text x={252} y={556} transform="rotate(-7 252 556)">
          CAPITOL PARK
        </Text>
        <Text x={404} y={700} transform="rotate(-7 404 700)">
          OAK PARK
        </Text>
        <Text x={126} y={828} transform="rotate(-7 126 828)">
          BROADWAY
        </Text>
      </G>
      <Text
        x={196}
        y={418}
        fill="#4a505a"
        fontFamily="Inter"
        fontSize={8.5}
        letterSpacing={1.2}
        transform="rotate(-33 196 418)"
      >
        TOWER BRIDGE
      </Text>
    </Svg>
  );
}

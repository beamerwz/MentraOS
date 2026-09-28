import Svg, {Circle, Path, SvgProps} from "react-native-svg"

interface LogoProps extends SvgProps {
  width?: number
  height?: number
}

/** G2 LABS mark. Deliberately independent from Mentra branding. */
export const G2LabsLogo: React.FC<LogoProps> = ({width = 72, height = 72, ...props}) => (
  <Svg width={width} height={height} viewBox="0 0 72 72" fill="none" {...props}>
    <Circle cx="36" cy="36" r="31" stroke="#A855F7" strokeWidth="3" />
    <Path
      d="M47 25C44.2 21.8 40.4 20 35.7 20C26.7 20 20 26.7 20 36C20 45.3 26.7 52 36 52C40.5 52 44.6 50.5 48 47.7V35H35V41H41.5V44.2C40 45.2 38.2 45.7 36 45.7C30.5 45.7 26.5 41.7 26.5 36C26.5 30.3 30.5 26.3 35.8 26.3C38.7 26.3 41.1 27.3 43.1 29.4L47 25Z"
      fill="#A855F7"
    />
    <Path d="M50 50H59V55H50V50Z" fill="#E9D5FF" />
  </Svg>
)

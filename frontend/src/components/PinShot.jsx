export default function PinShot({ pin, hero = false }) {
  const className = ["shot", pin.tall ? "tall" : "", hero ? "hero" : ""].filter(Boolean).join(" ");

  if (pin.imageUrl) {
    return <img className={className} src={pin.imageUrl} alt="" />;
  }

  return (
    <div className={className} style={{ background: pin.sky }}>
      <span className="band" style={{ height: pin.split, background: pin.ground }} />
    </div>
  );
}

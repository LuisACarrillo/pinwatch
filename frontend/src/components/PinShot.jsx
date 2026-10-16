import { useState } from "react";

export default function PinShot({ pin, hero = false }) {
  const [failedUrl, setFailedUrl] = useState("");
  const className = ["shot", pin.tall ? "tall" : "", hero ? "hero" : ""].filter(Boolean).join(" ");
  const showPhoto = pin.imageUrl && failedUrl !== pin.imageUrl;

  if (showPhoto) {
    return (
      <img className={className} src={pin.imageUrl} alt="" onError={() => setFailedUrl(pin.imageUrl)} />
    );
  }

  return (
    <div className={className} style={{ background: pin.sky }}>
      <span className="band" style={{ height: pin.split, background: pin.ground }} />
    </div>
  );
}

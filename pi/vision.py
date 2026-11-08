"""Headless visual odometry for the Raspberry Pi AI Camera.

Mount the camera facing a flat surface at a fixed distance (we use the ceiling),
with the top edge pointing forward. Frames are tracked with OpenCV:

    goodFeaturesToTrack -> calcOpticalFlowPyrLK -> estimateAffinePartial2D

The affine transform gives rotation and a pixel shift; pixels convert to metres
with the distance from the lens to that surface and the focal length:

    metres = pixels * plane_distance_m / focal_px

The same maths works facing up at a ceiling or down at a floor. No SLAM and no
calibration file are needed for a rough indoor demo. Walk a measured distance
once and adjust PI_CAMERA_SCALE if the path is too short/long. If the path goes
the wrong way, flip PI_CAMERA_FLIP_X / FLIP_Y / YAW_SIGN.

This module imports OpenCV and picamera2 lazily, so the Bluetooth-only uploader
still runs on a machine without them.
"""

from __future__ import annotations

import math
import threading
import time
from collections.abc import Mapping
from dataclasses import dataclass

POSE_BACKLOG_CAP = 6000  # ~20 minutes at 5 poses/s


class VisionConfigError(ValueError):
    """An invalid PI_CAMERA_* setting."""


@dataclass(frozen=True)
class VisionConfig:
    enabled: bool = True
    facing: str = "up"               # "up" (ceiling) or "down" (floor)
    plane_distance_m: float = 2.0    # lens to the surface it watches
    rotate: int = 0                  # 0/90/180/270 to suit the mount
    width: int = 640
    height: int = 480
    fps: int = 15
    focal_px: float = 485.0
    scale: float = 1.0
    flip_x: bool = False
    flip_y: bool = False
    yaw_sign: float = -1.0
    min_features: int = 20
    min_inliers: int = 12
    still_linear_m: float = 0.001
    still_angle_rad: float = math.radians(0.1)
    pose_hz: float = 5.0
    # Physical sanity limits: tracking glitches otherwise teleport the path.
    max_step_m: float = 0.75          # per camera frame
    max_speed_mps: float = 2.5        # walking/running, not teleporting
    max_turn_rad: float = math.radians(35)  # per frame

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> "VisionConfig":
        res = (env.get("PI_CAMERA_RES") or "640x480").lower().replace(" ", "")
        try:
            width, height = (int(part) for part in res.split("x", 1))
        except ValueError:
            raise VisionConfigError(f"PI_CAMERA_RES must look like 640x480 (got {res!r})") from None

        facing = (env.get("PI_CAMERA_FACING") or "up").strip().lower()
        if facing not in ("up", "down"):
            raise VisionConfigError("PI_CAMERA_FACING must be 'up' or 'down'")

        try:
            # PI_CAMERA_HEIGHT_M is the old name; keep it working if already set.
            distance = float(env.get("PI_CAMERA_DISTANCE_M")
                             or env.get("PI_CAMERA_HEIGHT_M") or 2.0)
            fps = int(env.get("PI_CAMERA_FPS") or 15)
            focal = float(env.get("PI_CAMERA_FOCAL_PX") or 485.0)
            scale = float(env.get("PI_CAMERA_SCALE") or 1.0)
            pose_hz = float(env.get("PI_CAMERA_POSE_HZ") or 5.0)
            yaw_sign = float(env.get("PI_CAMERA_YAW_SIGN") or -1.0)
            rotate = int(env.get("PI_CAMERA_ROTATE") or 0)
        except ValueError:
            raise VisionConfigError(
                "PI_CAMERA_DISTANCE_M, PI_CAMERA_FPS, PI_CAMERA_FOCAL_PX, "
                "PI_CAMERA_SCALE, PI_CAMERA_POSE_HZ, PI_CAMERA_YAW_SIGN and "
                "PI_CAMERA_ROTATE must be numbers"
            ) from None
        if distance <= 0:
            raise VisionConfigError("PI_CAMERA_DISTANCE_M must be greater than 0")
        if not 2 <= fps <= 60:
            raise VisionConfigError("PI_CAMERA_FPS must be between 2 and 60")
        if not 0.2 <= pose_hz <= 15:
            raise VisionConfigError("PI_CAMERA_POSE_HZ must be between 0.2 and 15")
        if yaw_sign not in (-1.0, 1.0):
            raise VisionConfigError("PI_CAMERA_YAW_SIGN must be 1 or -1")
        if rotate not in (0, 90, 180, 270):
            raise VisionConfigError("PI_CAMERA_ROTATE must be 0, 90, 180 or 270")

        return cls(
            enabled=_bool(env.get("PI_CAMERA"), True),
            facing=facing,
            plane_distance_m=distance,
            rotate=rotate,
            width=width,
            height=height,
            fps=fps,
            focal_px=focal,
            scale=scale,
            flip_x=_bool(env.get("PI_CAMERA_FLIP_X"), False),
            flip_y=_bool(env.get("PI_CAMERA_FLIP_Y"), False),
            yaw_sign=yaw_sign,
            pose_hz=pose_hz,
        )


def _bool(value: str | None, default: bool) -> bool:
    if value is None or not value.strip():
        return default
    return value.strip().lower() in ("1", "true", "yes", "on")


def _cv2():
    import cv2

    return cv2


@dataclass(frozen=True)
class Motion:
    """Camera movement in its own frame: +dx right, +dy forward, +dtheta right."""

    dx: float
    dy: float
    dtheta: float


@dataclass(frozen=True)
class Pose:
    t: float
    x: float
    y: float
    heading: float

    def as_dict(self) -> dict:
        return {"t": round(self.t, 3), "x": round(self.x, 3),
                "y": round(self.y, 3), "heading": round(self.heading, 4)}


class PoseIntegrator:
    """Turns per-frame camera motion into a start-relative x/y/heading pose."""

    def __init__(self, cfg: VisionConfig):
        self.cfg = cfg
        self.x = 0.0
        self.y = 0.0
        self.heading = 0.0
        self.rejected = 0
        self._last_t: float | None = None

    def pose(self, t: float) -> Pose:
        return Pose(t, self.x, self.y, self.heading)

    def update(self, motion: Motion | None, t: float) -> Pose:
        dt = t - self._last_t if self._last_t is not None else 0.0
        self._last_t = t
        if motion is None:
            return self.pose(t)

        # Reject physically impossible frame-to-frame motion. A bad feature fit
        # used to jump the path by 10-20 m; holding the last pose is far better.
        step = math.hypot(motion.dx, motion.dy)
        speed = step / dt if dt > 1e-6 else 0.0
        if (step > self.cfg.max_step_m
                or speed > self.cfg.max_speed_mps
                or abs(motion.dtheta) > self.cfg.max_turn_rad):
            self.rejected += 1
            return self.pose(t)

        still = (abs(motion.dx) < self.cfg.still_linear_m
                 and abs(motion.dy) < self.cfg.still_linear_m
                 and abs(motion.dtheta) < self.cfg.still_angle_rad)
        if still:
            return self.pose(t)
        # Rotate the camera-frame step into the world frame at the mid-heading.
        # heading is 0 = forward, positive = turned right (same as the phones).
        h = self.heading + motion.dtheta / 2
        self.x += motion.dx * math.cos(h) + motion.dy * math.sin(h)
        self.y += -motion.dx * math.sin(h) + motion.dy * math.cos(h)
        self.heading = _wrap(self.heading + motion.dtheta)
        return self.pose(t)


def _wrap(angle: float) -> float:
    return (angle + math.pi) % (2 * math.pi) - math.pi


def estimate_motion(prev_gray, gray, cfg: VisionConfig) -> Motion | None:
    """Estimate frame-to-frame motion from two grayscale images of the surface."""
    cv2 = _cv2()
    prev_pts = cv2.goodFeaturesToTrack(
        prev_gray, maxCorners=200, qualityLevel=0.01, minDistance=8, blockSize=7)
    if prev_pts is None or len(prev_pts) < cfg.min_features:
        return None

    next_pts, status, _ = cv2.calcOpticalFlowPyrLK(
        prev_gray, gray, prev_pts, None, winSize=(21, 21), maxLevel=3,
        criteria=(cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 30, 0.01))
    if next_pts is None or status is None:
        return None

    keep = status.reshape(-1) == 1
    good_prev = prev_pts.reshape(-1, 2)[keep]
    good_next = next_pts.reshape(-1, 2)[keep]
    if len(good_prev) < cfg.min_features:
        return None

    matrix, inliers = cv2.estimateAffinePartial2D(
        good_prev, good_next, method=cv2.RANSAC, ransacReprojThreshold=3.0)
    if matrix is None or inliers is None or int(inliers.sum()) < cfg.min_inliers:
        return None

    # A rigid surface-plane transform has roughly unit scale. A big change means
    # the camera height changed or the fit is bad; skip that frame.
    sx = math.hypot(matrix[0, 0], matrix[1, 0])
    sy = math.hypot(matrix[0, 1], matrix[1, 1])
    if not 0.8 <= (sx + sy) / 2 <= 1.2:
        return None

    # The affine translation is about the image origin. For camera movement we
    # want the shift of the optical centre, so remove the rotation-about-origin
    # part (otherwise a pure turn looks like a translation).
    cx, cy = prev_gray.shape[1] / 2.0, prev_gray.shape[0] / 2.0
    tx = float(matrix[0, 0] * cx + matrix[0, 1] * cy + matrix[0, 2] - cx)
    ty = float(matrix[1, 0] * cx + matrix[1, 1] * cy + matrix[1, 2] - cy)
    metres_per_pixel = cfg.plane_distance_m / cfg.focal_px * cfg.scale
    dx = -tx * metres_per_pixel
    dy = ty * metres_per_pixel
    if cfg.flip_x:
        dx = -dx
    if cfg.flip_y:
        dy = -dy

    dtheta = math.atan2(matrix[1, 0], matrix[0, 0]) * cfg.yaw_sign
    return Motion(dx, dy, dtheta)


class CameraPoseTracker:
    """Background thread: capture frames, track the surface, collect poses."""

    def __init__(self, cfg: VisionConfig):
        self.cfg = cfg
        self._picam = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._poses: list[dict] = []
        self._latest: dict | None = None
        self._status = "not started"

    @property
    def status(self) -> str:
        return self._status

    def start(self) -> None:
        if not self.cfg.enabled:
            self._status = "disabled"
            return
        try:
            _cv2()
        except ImportError as error:
            raise RuntimeError(
                "OpenCV is not installed (sudo apt install python3-opencv)") from error
        try:
            from picamera2 import Picamera2
        except ImportError as error:
            raise RuntimeError(
                "picamera2 is not installed (sudo apt install python3-picamera2)") from error

        self._stop.clear()
        try:
            self._picam = Picamera2()
            config = self._picam.create_video_configuration(
                main={"size": (self.cfg.width, self.cfg.height), "format": "RGB888"},
                buffer_count=4,
            )
            self._picam.configure(config)
            try:
                frame_us = max(1, int(1_000_000 / self.cfg.fps))
                self._picam.set_controls({"FrameDurationLimits": (frame_us, frame_us)})
            except Exception:
                pass  # some camera modes have a fixed frame rate
            self._picam.start()
            time.sleep(0.8)  # let auto-exposure settle
            try:  # keep brightness stable for feature tracking
                self._picam.set_controls({"AeEnable": False, "AwbEnable": False})
            except Exception:
                pass
        except Exception:
            try:
                self._picam.close()
            except Exception:
                pass
            self._picam = None
            raise

        self._status = f"{self.cfg.width}x{self.cfg.height} @ {self.cfg.fps} fps"
        self._thread = threading.Thread(target=self._loop, name="pi-vision", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2.0)
        self._status = "stopped"

    def take_poses(self) -> list[dict]:
        with self._lock:
            poses, self._poses = self._poses, []
        return poses

    def restore_poses(self, poses: list[dict]) -> None:
        """Put a failed upload's poses back at the front."""
        with self._lock:
            self._poses = list(poses) + self._poses
            if len(self._poses) > POSE_BACKLOG_CAP:
                del self._poses[: len(self._poses) - POSE_BACKLOG_CAP]

    def latest_pose(self) -> dict | None:
        with self._lock:
            return dict(self._latest) if self._latest else None

    def _emit(self, pose: Pose) -> None:
        item = pose.as_dict()
        with self._lock:
            self._poses.append(item)
            if len(self._poses) > POSE_BACKLOG_CAP:
                del self._poses[: len(self._poses) - POSE_BACKLOG_CAP]
            self._latest = item

    def _loop(self) -> None:
        cv2 = _cv2()
        integrator = PoseIntegrator(self.cfg)
        interval = 1.0 / self.cfg.pose_hz
        last_emit = 0.0
        prev_gray = None
        self._emit(integrator.pose(time.monotonic()))
        try:
            while not self._stop.is_set():
                frame = self._picam.capture_array("main")
                gray = cv2.cvtColor(frame, cv2.COLOR_RGB2GRAY)
                if gray.shape[1] != self.cfg.width or gray.shape[0] != self.cfg.height:
                    gray = cv2.resize(gray, (self.cfg.width, self.cfg.height),
                                      interpolation=cv2.INTER_AREA)
                if self.cfg.rotate == 90:
                    gray = cv2.rotate(gray, cv2.ROTATE_90_CLOCKWISE)
                elif self.cfg.rotate == 180:
                    gray = cv2.rotate(gray, cv2.ROTATE_180)
                elif self.cfg.rotate == 270:
                    gray = cv2.rotate(gray, cv2.ROTATE_90_COUNTERCLOCKWISE)
                now = time.monotonic()
                if prev_gray is not None:
                    motion = estimate_motion(prev_gray, gray, self.cfg)
                    if motion is None:
                        self._status = "searching for surface features"
                    else:
                        self._status = "tracking"
                        if integrator.rejected:
                            self._status += f" · {integrator.rejected} jumps skipped"
                    # Integrate on every frame, but only publish poses at pose_hz.
                    pose = integrator.update(motion, now)
                    if motion is not None and now - last_emit >= interval:
                        self._emit(pose)
                        last_emit = now
                prev_gray = gray
        except Exception as error:  # keep the Bluetooth uploader alive
            self._status = f"camera stopped: {error}"
        finally:
            try:
                self._picam.stop()
            except Exception:
                pass
            try:
                self._picam.close()
            except Exception:
                pass

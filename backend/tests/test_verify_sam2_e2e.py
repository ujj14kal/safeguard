
import base64
import json
import os

import pytest

torch = pytest.importorskip("torch")

pytestmark = pytest.mark.skipif(
    not os.environ.get("SAM2_CHECKPOINT_PATH") or os.environ.get("SAM2_MODE") != "sam2",
    reason="needs SAM2_CHECKPOINT_PATH and SAM2_MODE=sam2",
)

BLOB_JPEG_B64 = (
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcU"
    "FhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgo"
    "KCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCACAAIADASIA"
    "AhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQA"
    "AAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3"
    "ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWm"
    "p6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEA"
    "AwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSEx"
    "BhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElK"
    "U1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3"
    "uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD2Ciii"
    "gAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKZPNHbwSTTyJFDGpd3dg"
    "qqoGSST0AFcvqPxE8J6fOsU+t2zsV3AwBp1xkj7yAgHjpnP50AdXRXIWXxJ8I3lykEOtQq75wZo5"
    "Il4GeWdQo6dzXUWV3bX1slzZXENzbvnbLC4dWwcHBHB5BFAE9FFFABRRRQAUUUUAFFFFABRRRQAV"
    "5l8QvipaaBPPp2jRpeapEwWR3GYIjn5lOCCzDGMDgZ5OQVo+NPjWTQNPj0rSp3h1S7Xe0iqcxQnI"
    "yrdmJGBjOACeDtNfO9AGhrOt6nrc/m6tf3N2wZmUSyEqhY5O1eijgcAAcD0rPoooAKtadqN7pk7T"
    "abeXNpMy7C8ErRsVyDjII4yB+VVaKAPdPAPxeju3isPFQSGdmVI72NQsZ4xmUZ+U5HUfL83RQM17"
    "DXxVXt3wM8ayTuPDeqzvIwX/AEBipJCqCWjLegAyuRwARn7ooA9nooooAKKKKACiiigApk80dvBJ"
    "NPIkUMal3d2CqqgZJJPQAU+uU+Kt7Jp/w91uaFUZmhEBDgkbZGEbfjhjj3xQB8y+ItUk1vXb/Upt"
    "4a6maQK7lyik/Kue4UYA9gKz6KKACiiigAooooAKfBNJbzxzQSPFNGwdHRirKwOQQR0INMooA+xP"
    "DuqR63oVhqUOwLdQrIVRw4RiPmXPcqcg+4NaNec/AW9ku/AYhkVAtndSQRlQclTtk598yH8MV6NQ"
    "AUUUUAFFFFABXIfFu1mvPh3rUVsm91jSUjIHypIrsefRVJ/CuvqC+tYb6yuLS6TzLe4jaKRMkblY"
    "YIyORwe1AHxjRVrVbKTTNUvLCdkaa1meByhJUsrFTjOOMiqtABRRRQAUUUUAFFFFAH0Z8AbWa38C"
    "ySzJtS5vJJYjkHcoVUz7fMjDn0r0msjwjo66B4Z03TAEDW8IWTYxZTIeXIJ5wWLH8eg6Vr0AFFFF"
    "ABRRRQAUUUUAePfHbwc13APEemxO88KhLyONBzGAcSnuSvAPX5cdAprwuvtWvGPiF8I2nnn1HwoE"
    "DOwLadwigk/MY2JAA6HaeBzg9FoA8Rop88MlvPJDPG8U0bFHR1KsrA4IIPQg0ygAooooAK9a+Bng"
    "5r7UB4h1CJ1tbVv9EV0BWaTkFueyHoQPvYwflIo8A/CO7vnivvFAe0tQystn/wAtJlxn5iD+7GSB"
    "j733h8vBr3iCGO3gjhgjSKGNQiIihVVQMAADoAKAH0UUUAFFFFABRRRQAUUUUAFFFFAGdrOiaZrc"
    "HlatYW12oVlUyxgsgYYO1uqngcgg8D0ritR+Dvhe7nV4BfWShdpjgnypOTz84Y5/HHHSvRqKAPNr"
    "L4NeGbe5SWaTUbpFzmGaZQrcY52Kre/BHSuy0Hw1o2gIBpGm21swUp5qrmQqTkgucsRnHU9h6Cte"
    "igAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKAP/Z"
)


def test_sam2_end_to_end(client, mock_muse):
    response = client.post(
        "/verify",
        json={
            "frames_b64": [BLOB_JPEG_B64] * 4,
            "on_device_features": {"trend": 0.5},
            "boxes_xyxy": [[30.0, 30.0, 98.0, 98.0]],
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["path"] == "sam2+muse"
    assert body["sam2_latency_ms"] is not None
    sent = mock_muse[0]["json"]["messages"][1]["content"][0]["text"]
    assert "centroid_path" in sent

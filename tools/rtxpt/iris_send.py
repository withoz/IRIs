#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""IRIS — .irisb 를 실행 중인 렌더러로 보낸다.

라이브 링크 경로를 사람이 직접 확인하기 위한 도구이고, **Ruby 송신부(2d)의
참조 구현**이기도 합니다. 하는 일은 SketchUp 확장이 할 일과 똑같습니다.

    Hello  -> HelloAck   프로토콜 버전 교환, 텍스처 기준 경로 통지
    SyncBegin
    SceneBlob            .irisb 바이트 그대로
    SyncEnd -> SyncAck

파이프는 **일반 파일 열기**로 붙습니다. Ruby 의 File.open 과 같은 경로(CreateFile)
이므로 여기서 되는 것은 Ruby 에서도 됩니다.

사용법:
    python iris_send.py <파일.irisb> [--pipe iris] [--texture-base DIR]

--texture-base 를 주지 않으면 .irisb 가 있는 디렉터리를 씁니다. 프로브가
텍스처를 그 아래 textures/<모델명>/ 에 내보내기 때문입니다.
"""

import argparse
import json
import os
import struct
import sys
import time

HEADER = struct.Struct("<IIQ")   # type, flags, payloadLen

MSG_HELLO      = 1
MSG_HELLO_ACK  = 2
MSG_SYNC_BEGIN = 3
MSG_SCENE_BLOB = 4
MSG_SYNC_END   = 5
MSG_SYNC_ACK   = 6
MSG_BYE        = 7

PROTOCOL_VERSION = 1

NAMES = {
    MSG_HELLO: "Hello", MSG_HELLO_ACK: "HelloAck",
    MSG_SYNC_BEGIN: "SyncBegin", MSG_SCENE_BLOB: "SceneBlob",
    MSG_SYNC_END: "SyncEnd", MSG_SYNC_ACK: "SyncAck", MSG_BYE: "Bye",
}


def pipe_path(name):
    """\\\\.\\pipe\\<name>  — 역슬래시를 소스에 직접 쓰지 않는다.

    편집 도구를 거치며 개수가 어긋나 실제로 한 번 깨졌다.
    """
    b = chr(92)
    return f"{b}{b}.{b}pipe{b}{name}"


def open_pipe(path, timeout_s=5.0):
    deadline = time.time() + timeout_s
    last = None
    while time.time() < deadline:
        try:
            return open(path, "r+b", buffering=0)
        except OSError as e:
            last = e
            time.sleep(0.15)
    raise SystemExit(
        f"파이프를 열지 못했습니다: {path}\n"
        f"  {last}\n"
        f"  렌더러가 실행 중인지 확인하십시오. 'Permission denied' 는 보통\n"
        f"  낡은 인스턴스가 이름을 잡고 있다는 뜻입니다."
    )


def send(io, msg_type, payload=b"", flags=0):
    io.write(HEADER.pack(msg_type, flags, len(payload)))
    if payload:
        io.write(payload)
    io.flush()


def recv(io):
    head = io.read(HEADER.size)
    if not head or len(head) < HEADER.size:
        raise SystemExit("응답 도중 연결이 끊겼습니다")
    msg_type, flags, length = HEADER.unpack(head)
    body = b""
    while len(body) < length:
        chunk = io.read(length - len(body))
        if not chunk:
            raise SystemExit("페이로드 도중 연결이 끊겼습니다")
        body += chunk
    return msg_type, flags, body


def main():
    ap = argparse.ArgumentParser(description=".irisb 를 실행 중인 IRIS 렌더러로 보낸다")
    ap.add_argument("scene", help="보낼 .irisb 파일")
    ap.add_argument("--pipe", default="iris", help="파이프 이름 (기본 iris)")
    ap.add_argument("--texture-base", default=None,
                    help="텍스처 기준 디렉터리. 기본은 .irisb 가 있는 곳")
    ap.add_argument("--repeat", type=int, default=1, help="같은 씬을 여러 번 보낸다 (지연 측정용)")
    args = ap.parse_args()

    if not os.path.isfile(args.scene):
        raise SystemExit(f"파일이 없습니다: {args.scene}")

    blob = open(args.scene, "rb").read()
    tex_base = args.texture_base or os.path.dirname(os.path.abspath(args.scene))

    path = pipe_path(args.pipe)
    print(f"파이프: {path}")
    print(f"씬:     {args.scene}  ({len(blob):,} bytes)")
    print(f"텍스처: {tex_base}")
    print()

    io = open_pipe(path)
    try:
        hello = json.dumps({
            "protocol": PROTOCOL_VERSION,
            "app": "iris_send.py",
            "model": os.path.basename(args.scene),
            "unit": "meter",
            "up_axis": "z",
            "texture_base": tex_base,
        }, ensure_ascii=False).encode("utf-8")

        send(io, MSG_HELLO, hello)
        t, _, body = recv(io)
        ack = json.loads(body.decode("utf-8")) if body else {}
        print(f"<- {NAMES.get(t, t)}: {ack}")
        if t != MSG_HELLO_ACK or not ack.get("accepted"):
            raise SystemExit(f"렌더러가 연결을 거절했습니다: {ack.get('reason', '(이유 없음)')}")

        for i in range(args.repeat):
            t0 = time.perf_counter()
            send(io, MSG_SYNC_BEGIN, json.dumps({"seq": i + 1}).encode("utf-8"))
            send(io, MSG_SCENE_BLOB, blob)
            send(io, MSG_SYNC_END, json.dumps({"seq": i + 1}).encode("utf-8"))
            t, _, body = recv(io)
            ms = (time.perf_counter() - t0) * 1000.0
            if t != MSG_SYNC_ACK:
                raise SystemExit(f"예상 밖 응답: {NAMES.get(t, t)}")
            print(f"[{i+1}] 전송+확인 {ms:7.1f} ms  ({len(blob)/1048576/(ms/1000):,.0f} MB/s)  {body.decode('utf-8')}")

        send(io, MSG_BYE)
        print("\n보냈습니다. 렌더러 화면이 바뀌어야 합니다.")
    finally:
        io.close()


if __name__ == "__main__":
    sys.exit(main())

//! SWTOS multiplexed transport, version 1.

pub const SYNC: [u8; 2] = [0xa5, 0x5a];
pub const VERSION: u8 = 1;
pub const MAX_PAYLOAD: usize = 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum FrameType {
    TtyInput = 1,
    TtyOutput = 2,
    ChannelOpen = 3,
    ChannelClose = 4,
    ChannelTitle = 5,
    Uptime = 6,
    WallClock = 7,
    ResourceSnapshot = 8,
    DebugRequest = 9,
    DebugResponse = 10,
    ProtocolError = 11,
    Hello = 12,
    HelloAck = 13,
}

impl TryFrom<u8> for FrameType {
    type Error = DecodeError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        Ok(match value {
            1 => Self::TtyInput,
            2 => Self::TtyOutput,
            3 => Self::ChannelOpen,
            4 => Self::ChannelClose,
            5 => Self::ChannelTitle,
            6 => Self::Uptime,
            7 => Self::WallClock,
            8 => Self::ResourceSnapshot,
            9 => Self::DebugRequest,
            10 => Self::DebugResponse,
            11 => Self::ProtocolError,
            12 => Self::Hello,
            13 => Self::HelloAck,
            other => return Err(DecodeError::UnknownType(other)),
        })
    }
}

pub const NEGOTIATION_PAYLOAD: &[u8] = b"SWT1";

pub fn hello() -> Frame {
    Frame {
        kind: FrameType::Hello,
        channel: 0,
        payload: NEGOTIATION_PAYLOAD.to_vec(),
    }
}

pub fn hello_ack() -> Frame {
    Frame {
        kind: FrameType::HelloAck,
        channel: 0,
        payload: NEGOTIATION_PAYLOAD.to_vec(),
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum Mode {
    #[default]
    Plain,
    Framed,
}

#[derive(Default)]
pub struct Negotiator {
    mode: Mode,
}

impl Negotiator {
    pub fn mode(&self) -> Mode {
        self.mode
    }

    pub fn observe(&mut self, frame: &Frame) -> bool {
        if self.mode == Mode::Plain
            && frame.kind == FrameType::HelloAck
            && frame.channel == 0
            && frame.payload == NEGOTIATION_PAYLOAD
        {
            self.mode = Mode::Framed;
            true
        } else {
            false
        }
    }

    pub fn disconnect(&mut self) {
        self.mode = Mode::Plain;
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Frame {
    pub kind: FrameType,
    pub channel: u8,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn encode(&self) -> Result<Vec<u8>, EncodeError> {
        if self.payload.len() > MAX_PAYLOAD || self.payload.len() > u16::MAX as usize {
            return Err(EncodeError::PayloadTooLong(self.payload.len()));
        }
        let length = self.payload.len() as u16;
        let mut bytes = Vec::with_capacity(8 + self.payload.len());
        bytes.extend_from_slice(&SYNC);
        bytes.extend_from_slice(&[
            VERSION,
            self.kind as u8,
            self.channel,
            length as u8,
            (length >> 8) as u8,
        ]);
        bytes.extend_from_slice(&self.payload);
        bytes.push(checksum(&bytes[2..]));
        Ok(bytes)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum EncodeError {
    PayloadTooLong(usize),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DecodeError {
    BadVersion(u8),
    UnknownType(u8),
    PayloadTooLong(usize),
    BadChecksum,
}

#[derive(Default)]
pub struct Decoder {
    buffer: Vec<u8>,
}

impl Decoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn clear(&mut self) {
        self.buffer.clear();
    }

    pub fn push(&mut self, input: &[u8]) -> Vec<Result<Frame, DecodeError>> {
        self.buffer.extend_from_slice(input);
        let mut output = Vec::new();
        loop {
            let Some(sync) = self.buffer.windows(2).position(|window| window == SYNC) else {
                if self.buffer.last() == Some(&SYNC[0]) {
                    self.buffer.drain(..self.buffer.len() - 1);
                } else {
                    self.buffer.clear();
                }
                break;
            };
            self.buffer.drain(..sync);
            if self.buffer.len() < 7 {
                break;
            }
            if self.buffer[2] != VERSION {
                output.push(Err(DecodeError::BadVersion(self.buffer[2])));
                self.buffer.drain(..1);
                continue;
            }
            let length = usize::from(self.buffer[5]) | (usize::from(self.buffer[6]) << 8);
            if length > MAX_PAYLOAD {
                output.push(Err(DecodeError::PayloadTooLong(length)));
                self.buffer.drain(..1);
                continue;
            }
            let frame_len = 8 + length;
            if self.buffer.len() < frame_len {
                break;
            }
            let expected = checksum(&self.buffer[2..frame_len - 1]);
            if self.buffer[frame_len - 1] != expected {
                output.push(Err(DecodeError::BadChecksum));
                self.buffer.drain(..1);
                continue;
            }
            match FrameType::try_from(self.buffer[3]) {
                Ok(kind) => output.push(Ok(Frame {
                    kind,
                    channel: self.buffer[4],
                    payload: self.buffer[7..frame_len - 1].to_vec(),
                })),
                Err(error) => output.push(Err(error)),
            }
            self.buffer.drain(..frame_len);
        }
        output
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum StreamItem {
    Plain(Vec<u8>),
    Frame(Frame),
    Error(DecodeError),
}

/// Preserves recovery-terminal output until the target acknowledges framed
/// mode, then decodes only versioned frames. A possible ACK prefix is retained
/// across reads so fragmented negotiation cannot leak binary bytes.
pub struct ConnectionDecoder {
    mode: Mode,
    pending: Vec<u8>,
    framed: Decoder,
}

impl Default for ConnectionDecoder {
    fn default() -> Self {
        Self {
            mode: Mode::Plain,
            pending: Vec::new(),
            framed: Decoder::new(),
        }
    }
}

impl ConnectionDecoder {
    pub fn mode(&self) -> Mode {
        self.mode
    }

    pub fn push(&mut self, input: &[u8]) -> Vec<StreamItem> {
        if self.mode == Mode::Framed {
            return self
                .framed
                .push(input)
                .into_iter()
                .map(|result| match result {
                    Ok(frame) => StreamItem::Frame(frame),
                    Err(error) => StreamItem::Error(error),
                })
                .collect();
        }

        self.pending.extend_from_slice(input);
        let ack = hello_ack().encode().expect("HELLO_ACK payload is bounded");
        let mut output = Vec::new();
        if let Some(position) = self
            .pending
            .windows(ack.len())
            .position(|candidate| candidate == ack)
        {
            if position != 0 {
                output.push(StreamItem::Plain(self.pending[..position].to_vec()));
            }
            output.push(StreamItem::Frame(hello_ack()));
            let trailing = self.pending[position + ack.len()..].to_vec();
            self.pending.clear();
            self.mode = Mode::Framed;
            output.extend(self.push(&trailing));
            return output;
        }

        let retained = longest_suffix_prefix(&self.pending, &ack);
        let plain_length = self.pending.len() - retained;
        if plain_length != 0 {
            output.push(StreamItem::Plain(self.pending[..plain_length].to_vec()));
            self.pending.drain(..plain_length);
        }
        output
    }

    pub fn disconnect(&mut self) -> Vec<StreamItem> {
        let output = if self.pending.is_empty() {
            Vec::new()
        } else {
            vec![StreamItem::Plain(std::mem::take(&mut self.pending))]
        };
        self.mode = Mode::Plain;
        self.framed.clear();
        output
    }
}

fn longest_suffix_prefix(bytes: &[u8], prefix: &[u8]) -> usize {
    let limit = bytes.len().min(prefix.len().saturating_sub(1));
    (1..=limit)
        .rev()
        .find(|length| bytes[bytes.len() - length..] == prefix[..*length])
        .unwrap_or(0)
}

fn checksum(bytes: &[u8]) -> u8 {
    bytes.iter().fold(0_u8, |sum, byte| sum.wrapping_add(*byte))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(payload: &[u8]) -> Frame {
        Frame {
            kind: FrameType::TtyInput,
            channel: 3,
            payload: payload.to_vec(),
        }
    }

    #[test]
    fn round_trip_every_split_point_and_literal_sync() {
        let expected = frame(&[0, 0xa5, 0x5a, 0xff, 42]);
        let encoded = expected.encode().unwrap();
        for split in 0..encoded.len() {
            let mut decoder = Decoder::new();
            assert!(decoder.push(&encoded[..split]).is_empty());
            assert_eq!(decoder.push(&encoded[split..]), vec![Ok(expected.clone())]);
        }
    }

    #[test]
    fn garbage_corruption_unknown_type_and_resynchronization() {
        let good = frame(b"good").encode().unwrap();
        let mut bad = frame(b"bad").encode().unwrap();
        let last = bad.len() - 1;
        bad[last] ^= 0x80;
        let mut unknown = frame(b"unknown").encode().unwrap();
        unknown[3] = 0xfe;
        unknown[last + 4] = checksum(&unknown[2..last + 4]);
        let mut stream = b"garbage".to_vec();
        stream.extend_from_slice(&bad);
        stream.extend_from_slice(&unknown);
        stream.extend_from_slice(&good);
        let results = Decoder::new().push(&stream);
        assert!(results.contains(&Err(DecodeError::BadChecksum)));
        assert!(results.contains(&Err(DecodeError::UnknownType(0xfe))));
        assert_eq!(results.last(), Some(&Ok(frame(b"good"))));
    }

    #[test]
    fn reconnect_discards_partial_frame() {
        let encoded = frame(b"fresh").encode().unwrap();
        let mut decoder = Decoder::new();
        decoder.push(&encoded[..5]);
        decoder.clear();
        assert_eq!(decoder.push(&encoded), vec![Ok(frame(b"fresh"))]);
    }

    #[test]
    fn negotiation_requires_exact_ack_and_resets_on_disconnect() {
        let mut negotiation = Negotiator::default();
        assert!(!negotiation.observe(&hello()));
        assert!(!negotiation.observe(&Frame {
            kind: FrameType::HelloAck,
            channel: 1,
            payload: NEGOTIATION_PAYLOAD.to_vec(),
        }));
        assert!(!negotiation.observe(&Frame {
            kind: FrameType::HelloAck,
            channel: 0,
            payload: b"SWT0".to_vec(),
        }));
        assert!(negotiation.observe(&Frame {
            kind: FrameType::HelloAck,
            channel: 0,
            payload: NEGOTIATION_PAYLOAD.to_vec(),
        }));
        assert_eq!(negotiation.mode(), Mode::Framed);
        negotiation.disconnect();
        assert_eq!(negotiation.mode(), Mode::Plain);
    }

    #[test]
    fn connection_preserves_plain_output_and_fragmented_ack() {
        let ack = hello_ack().encode().unwrap();
        let output = frame(b"after").encode().unwrap();
        for split in 0..ack.len() {
            let mut connection = ConnectionDecoder::default();
            assert_eq!(
                connection.push(b"boot\n"),
                vec![StreamItem::Plain(b"boot\n".to_vec())]
            );
            assert!(connection.push(&ack[..split]).is_empty());
            let mut trailing = ack[split..].to_vec();
            trailing.extend_from_slice(&output);
            assert_eq!(
                connection.push(&trailing),
                vec![
                    StreamItem::Frame(hello_ack()),
                    StreamItem::Frame(frame(b"after"))
                ]
            );
            assert_eq!(connection.mode(), Mode::Framed);
        }
    }

    #[test]
    fn connection_flushes_partial_negotiation_on_disconnect() {
        let ack = hello_ack().encode().unwrap();
        let mut connection = ConnectionDecoder::default();
        assert!(connection.push(&ack[..5]).is_empty());
        assert_eq!(
            connection.disconnect(),
            vec![StreamItem::Plain(ack[..5].to_vec())]
        );
        assert_eq!(connection.mode(), Mode::Plain);
    }
}

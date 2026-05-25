pub fn add(left: u32, right: u32) -> u32 {
    left + right
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exposes_red_verdicts() {
        assert_eq!(add(2, 2), 5);
    }
}

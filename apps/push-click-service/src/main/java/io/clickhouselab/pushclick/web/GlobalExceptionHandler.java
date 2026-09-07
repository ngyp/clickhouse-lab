package io.clickhouselab.pushclick.web;

import jakarta.validation.ConstraintViolationException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

import java.util.Map;

/**
 * {@code @Validated} 컨트롤러의 {@code @RequestParam}/{@code @PathVariable}
 * 제약(예: {@link CampaignStatsController}의 hours 상한) 위반은 기본적으로
 * {@link ConstraintViolationException}으로 던져지는데, 이는 {@code @Valid
 * @RequestBody}의 {@code MethodArgumentNotValidException}과 달리 스프링이
 * 자동으로 400으로 변환해주지 않는다 — 핸들러가 없으면 500으로 노출되어
 * 클라이언트 입력 오류가 서버 내부 오류처럼 보이고, 스택트레이스가 응답에
 * 섞여 나갈 위험도 있다. 여기서 명시적으로 400 + 최소한의 메시지만 반환한다.
 */
@RestControllerAdvice
public class GlobalExceptionHandler {

    @ExceptionHandler(ConstraintViolationException.class)
    public ResponseEntity<Map<String, String>> handleConstraintViolation(ConstraintViolationException e) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST)
                .body(Map.of("error", "Invalid request parameters"));
    }
}

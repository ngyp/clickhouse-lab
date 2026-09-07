package io.clickhouselab.pushclick.web;

import io.clickhouselab.pushclick.service.CustomerService;
import io.clickhouselab.pushclick.web.dto.CreateCustomerRequest;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/customers")
public class CustomerController {

    private final CustomerService customerService;

    public CustomerController(CustomerService customerService) {
        this.customerService = customerService;
    }

    @PostMapping
    public ResponseEntity<Void> createOrUpdate(@Valid @RequestBody CreateCustomerRequest request) {
        customerService.createOrUpdate(request);
        return ResponseEntity.accepted().build();
    }
}

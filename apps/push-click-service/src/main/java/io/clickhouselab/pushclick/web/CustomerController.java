package io.clickhouselab.pushclick.web;

import io.clickhouselab.pushclick.service.CustomerService;
import io.clickhouselab.pushclick.web.dto.CreateCustomerRequest;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.responses.ApiResponse;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/customers")
@Tag(name = "Customers", description = "Manage customer records that push sends and clicks are attributed to.")
public class CustomerController {

    private final CustomerService customerService;

    public CustomerController(CustomerService customerService) {
        this.customerService = customerService;
    }

    @Operation(
            operationId = "createOrUpdateCustomer",
            summary = "Create or update a customer",
            description = "Creates a new customer record, or updates an existing one if a customer with the " +
                    "same customerId already exists (upsert). Call this before recording push or click " +
                    "events for a customer, or whenever the customer's device token or segment changes."
    )
    @ApiResponse(responseCode = "202", description = "The customer record was accepted and will be written asynchronously.")
    @PostMapping
    public ResponseEntity<Void> createOrUpdate(@Valid @RequestBody CreateCustomerRequest request) {
        customerService.createOrUpdate(request);
        return ResponseEntity.accepted().build();
    }
}

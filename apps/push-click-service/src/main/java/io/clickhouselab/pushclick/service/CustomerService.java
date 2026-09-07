package io.clickhouselab.pushclick.service;

import io.clickhouselab.pushclick.repository.CustomerRepository;
import io.clickhouselab.pushclick.web.dto.CreateCustomerRequest;
import org.springframework.stereotype.Service;

@Service
public class CustomerService {

    private final CustomerRepository customerRepository;

    public CustomerService(CustomerRepository customerRepository) {
        this.customerRepository = customerRepository;
    }

    public void createOrUpdate(CreateCustomerRequest request) {
        String segment = request.segment() != null ? request.segment() : "default";
        customerRepository.upsert(request.customerId(), request.deviceToken(), segment);
    }
}

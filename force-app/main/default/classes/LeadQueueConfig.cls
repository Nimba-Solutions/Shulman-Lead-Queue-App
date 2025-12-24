public class LeadQueueConfig {
    public static final Map<String, Integer> CASE_TYPE_PRIORITY = new Map<String, Integer>{
        'Labor Law' => 1,
        'MVA' => 2,
        'Premises' => 3,
        'WC & PI' => 4,
        'Personal Injury' => 5,
        'Worker Compensation' => 6,
        'Other' => 7,
        'Medical Malpractice' => 9,
        'Employment Law' => 10,
        'Federal Workers\' Compensation' => 11,
        'Immigration' => 12,
        'Mass Tort/Product Liability' => 13,
        'Real Estate/Closings' => 14,
        'Landlord-Tenant' => 15,
        'Family Law' => 16,
        'Estate Planning' => 17,
        'Business/Corporate' => 18,
        'Criminal Defense' => 19,
        'Traffic' => 20,
        'Veteran Disability' => 21
    };
    
    public static final Integer DEFAULT_CASE_TYPE_PRIORITY = 8;
}

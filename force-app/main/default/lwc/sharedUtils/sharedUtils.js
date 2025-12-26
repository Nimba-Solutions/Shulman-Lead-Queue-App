export class SharedUtils {
    static getErrorMessage(error) {
        const userFriendlyMessages = {
            'FIELD_CUSTOM_VALIDATION_EXCEPTION': 'Invalid data provided',
            'INSUFFICIENT_ACCESS_OR_READONLY': 'Access denied',
            'QUERY_TIMEOUT': 'Request timed out, please try again',
            'REQUIRED_FIELD_MISSING': 'Required information is missing',
            'FIELD_INTEGRITY_EXCEPTION': 'Data validation error'
        };
        
        const errorCode = error?.body?.exceptionType || error?.name;
        return userFriendlyMessages[errorCode] || 'An error occurred. Please contact your administrator.';
    }

    static formatTime(dateTimeValue) {
        if (!dateTimeValue) return '';
        
        try {
            const dateTime = new Date(dateTimeValue);
            return dateTime.toLocaleTimeString('en-US', {
                hour: 'numeric',
                minute: '2-digit',
                hour12: true
            });
        } catch (error) {
            return '';
        }
    }

    static formatCallDateTime(dateTimeValue) {
        if (!dateTimeValue) return '';
        
        try {
            const dateTime = new Date(dateTimeValue);
            return dateTime.toLocaleDateString('en-US', {
                month: '2-digit',
                day: '2-digit',
                year: 'numeric'
            }) + ' ' + dateTime.toLocaleTimeString('en-US', {
                hour: 'numeric',
                minute: '2-digit',
                hour12: true
            });
        } catch (error) {
            return '';
        }
    }

    static normalizeRecordId(recordId) {
        if (!recordId) {
            return recordId;
        }
        return recordId.endsWith('-assigned') ? recordId.slice(0, -9) : recordId;
    }

    static get CONSTANTS() {
        return {
            REFRESH_INTERVAL: 30000
        };
    }

    static get dueDateOptions() {
        return [
            { label: 'All Dates', value: '' },
            { label: 'Due Today', value: 'today' },
            { label: 'Due This Week', value: 'thisWeek' },
            { label: 'Due Next Week', value: 'nextWeek' }
        ];
    }
}
